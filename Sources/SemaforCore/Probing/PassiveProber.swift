import Foundation

/// Watches the CLIs' own session logs while the user works (spec §6/§7):
/// tails appended lines, feeds per-provider extractors, stores the resulting
/// passive samples, and runs the control gate so verdicts can blame the
/// network when robots.txt is also slow. No model requests are ever made.
public actor PassiveProber {
    /// Controls only run while a sample this fresh exists (spec §8.2).
    private static let controlTriggerRecency: TimeInterval = 15 * 60

    private struct DayCount {
        let day: String
        var okCount: Int
    }

    private let providersById: [ProviderID: any Provider]
    private let tailer: SessionLogTailer
    private var extractors: [ProviderID: any SessionLogExtracting]
    private let control: any ControlProbing
    private let writer: (any LimitsWriting)?
    private let settings: AppSettings
    private let dateNow: @Sendable () -> Date
    private let clock: ClockBox

    private var latest: [String: ProbeSample] = [:]  // "provider|model" → newest
    private var lastSampleAt: [ProviderID: Date] = [:]
    private var lastControl: [ProviderID: Date] = [:]
    private var measuredToday: [ProviderID: DayCount] = [:]
    private var paused = false
    private var started = false
    private var hasBackfilled = false
    private let hub = ProbeHub()

    public init<C: Clock & Sendable>(
        providers: [any Provider],
        tailer: SessionLogTailer,
        extractors: [ProviderID: any SessionLogExtracting],
        control: any ControlProbing,
        writer: (any LimitsWriting)?,
        settings: AppSettings,
        dateNow: @escaping @Sendable () -> Date = Date.init,
        clock: C = ContinuousClock()
    ) where C.Instant.Duration == Duration {
        self.providersById = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.tailer = tailer
        self.extractors = extractors
        self.control = control
        self.writer = writer
        self.settings = settings
        self.dateNow = dateNow
        self.clock = ClockBox(clock)
    }

    /// Loads tailer offsets, backfills history once, then loops on the scan
    /// interval. Repeat calls are no-ops (spec §7: backfill runs once).
    public func start() {
        guard !started else { return }
        started = true
        Task { await self.runLoop() }
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    /// One tail → ingest → finish → store pass, plus the control gate.
    public func scanNow() async {
        let now = dateNow()
        for id in providersById.keys {
            await scanProvider(id, now: now, storeOnly: false)
        }
        try? await tailer.saveState()
        await runControlGate(now: now)
    }

    public func latestProbes() -> [ProbeSample] {
        latest.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// `.ok` samples the prober emitted during the current local day
    /// (spec §9 popover footnote "measured N today").
    public func measuredCountToday(provider: ProviderID) -> Int {
        guard let entry = measuredToday[provider],
              entry.day == Self.dayKey(dateNow())
        else { return 0 }
        return entry.okCount
    }

    public nonisolated func updates() -> AsyncStream<[ProbeSample]> {
        hub.subscribe()
    }

    // MARK: - Loop

    private func runLoop() async {
        await tailer.loadState()
        if !hasBackfilled {
            hasBackfilled = true
            let now = dateNow()
            for id in providersById.keys {
                await scanProvider(id, now: now, storeOnly: true)
            }
            try? await tailer.saveState()
        }
        while started {
            if !paused {
                await scanNow()
            }
            let base = Double(max(5, settings.scanIntervalSeconds))
            try? await clock.sleep(for: .seconds(base * jitter()))
        }
    }

    /// ±20 % jitter, deterministically seeded from the provider ids present.
    private func jitter() -> Double {
        let seed = providersById.keys.reduce(7) { total, id in
            id.rawValue.unicodeScalars.reduce(total) { ($0 &* 31 &+ Int($1.value)) % 100_000 }
        }
        return 1 + Double(abs(seed) % 41 - 20) / 100
    }

    // MARK: - One provider pass

    private func scanProvider(_ id: ProviderID, now: Date, storeOnly: Bool) async {
        guard let provider = providersById[id], var extractor = extractors[id] else { return }
        let lines = await tailer.pendingLines(in: provider.sessionLogPaths, namePattern: "*.jsonl")
        for line in lines {
            extractor.ingest(line)
        }
        // finish every pass: quiet-gated samples can complete without new lines.
        var samples = extractor.finish(now: now)
        extractors[id] = extractor
        if storeOnly {
            let windowStart = now.addingTimeInterval(-Double(settings.backfillDays) * 86_400)
            samples = samples.filter { $0.timestamp >= windowStart && $0.timestamp <= now }
        }
        for sample in samples {
            try? await writer?.append(.probe(sample))
            guard !storeOnly else { continue }
            latest["\(id.rawValue)|\(sample.model)"] = sample
            if lastSampleAt[id] == nil || sample.timestamp > lastSampleAt[id]! {
                lastSampleAt[id] = sample.timestamp
            }
            if sample.outcome == .ok {
                let day = Self.dayKey(now)
                if var entry = measuredToday[id], entry.day == day {
                    entry.okCount += 1
                    measuredToday[id] = entry
                } else {
                    measuredToday[id] = DayCount(day: day, okCount: 1)
                }
            }
        }
        if !storeOnly, !samples.isEmpty {
            hub.publish(latestProbes())
        }
    }

    // MARK: - Control gate

    private func runControlGate(now: Date) async {
        guard settings.controlProbeEnabled else { return }
        for id in providersById.keys {
            guard let lastSeen = lastSampleAt[id],
                  now.timeIntervalSince(lastSeen) <= Self.controlTriggerRecency
            else { continue }
            let interval = Double(settings.controlIntervalMinutes) * 60
            if let previous = lastControl[id], now.timeIntervalSince(previous) < interval {
                continue
            }
            lastControl[id] = now
            let sample = await control.measure(id)
            try? await writer?.append(.control(sample))
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private final class ProbeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[ProbeSample]>.Continuation] = [:]
    private var latest: [ProbeSample]?

    func subscribe() -> AsyncStream<[ProbeSample]> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.lock()
            continuations[subscriberID] = continuation
            let latest = self.latest
            lock.unlock()
            if let latest {
                continuation.yield(latest)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[subscriberID] = nil
                self.lock.unlock()
            }
        }
    }

    func publish(_ samples: [ProbeSample]) {
        lock.lock()
        latest = samples
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(samples)
        }
    }
}
