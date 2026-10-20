import Foundation

/// Polls each provider on a fixed jittered interval plus manual refresh,
/// keeps the latest snapshot per provider (failures never blank previous
/// data), forwards snapshots to the sample store, and publishes updates.
/// One attempt per interval — no retry storms (spec §10).
public actor PollScheduler {
    private let providersById: [ProviderID: any Provider]
    private let writer: (any LimitsWriting)?
    private let settings: AppSettings
    private let clock: ClockBox

    private var currentSnapshots: [ProviderID: ProviderSnapshot] = [:]
    private var paused = false
    private var started = false
    private var inFlight: Set<ProviderID> = []
    private var pendingRefresh: Set<ProviderID> = []
    private let hub = SubscriberHub()

    public init<C: Clock & Sendable>(
        providers: [any Provider],
        writer: (any LimitsWriting)?,
        settings: AppSettings,
        clock: C = ContinuousClock()
    ) where C.Instant.Duration == Duration {
        self.init(
            providers: providers,
            writer: writer,
            settings: settings,
            clock: ClockBox(clock))
    }

    private init(
        providers: [any Provider],
        writer: (any LimitsWriting)?,
        settings: AppSettings,
        clock: ClockBox
    ) {
        self.providersById = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.writer = writer
        self.settings = settings
        self.clock = clock
    }

    public func start() {
        guard !started else { return }
        started = true
        for id in providersById.keys {
            Task { await self.runLoop(id: id) }
        }
    }

    /// Manual refresh; calls while a poll is in flight coalesce into one
    /// follow-up poll. Disabled providers (hal off, say) are skipped
    /// entirely — their existing snapshot simply stays put.
    public func refresh(_ id: ProviderID) async {
        guard let provider = providersById[id], provider.pollingEnabled else { return }
        if inFlight.contains(id) {
            pendingRefresh.insert(id)
            return
        }
        await runFetch(id: id, provider: provider)
        while pendingRefresh.contains(id) {
            pendingRefresh.remove(id)
            await runFetch(id: id, provider: provider)
        }
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    public func snapshots() -> [ProviderID: ProviderSnapshot] { currentSnapshots }

    public func isStale(_ id: ProviderID, now: Date) -> Bool {
        guard let snapshot = currentSnapshots[id] else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt)
            > 3 * Double(settings.pollIntervalMinutes) * 60
    }

    public nonisolated func updates() -> AsyncStream<[ProviderID: ProviderSnapshot]> {
        hub.subscribe()
    }

    private func runLoop(id: ProviderID) async {
        while started {
            if !paused {
                await refresh(id)
            }
            let base = Double(settings.pollIntervalMinutes) * 60
            try? await clock.sleep(for: Duration.seconds(base * jitter(for: id)))
        }
    }

    private func runFetch(id: ProviderID, provider: any Provider) async {
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let now = Date()
        do {
            let windows = try await provider.fetchLimits()
            // Status page rides along with the limits poll; a feed failure
            // must never disturb the limits snapshot (spec §8.2).
            let status = try? await provider.statusPage()
            currentSnapshots[id] = ProviderSnapshot(
                providerID: id, windows: windows, fetchedAt: now, lastError: nil,
                officialStatus: status)
            try? await writer?.append(.limits(id, windows, fetchedAt: now))
            if let status {
                try? await writer?.append(.status(id, status, fetchedAt: now))
            }
        } catch let error as ProviderError {
            let previous = currentSnapshots[id]
            currentSnapshots[id] = ProviderSnapshot(
                providerID: id,
                windows: previous?.windows ?? [],
                fetchedAt: previous?.fetchedAt ?? now,
                lastError: error,
                officialStatus: previous?.officialStatus)
        } catch {
            let previous = currentSnapshots[id]
            currentSnapshots[id] = ProviderSnapshot(
                providerID: id,
                windows: previous?.windows ?? [],
                fetchedAt: previous?.fetchedAt ?? now,
                lastError: .network,
                officialStatus: previous?.officialStatus)
        }
        hub.publish(currentSnapshots)
    }

    /// Deterministic ±10% jitter seeded from the provider id, so parallel
    /// providers do not stampede and tests stay reproducible.
    private func jitter(for id: ProviderID) -> Double {
        let seed = id.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1000 }
        return 1 + Double(seed % 21 - 10) / 100
    }
}

/// Type-erased sleep: `Clock`'s associated `Instant` makes `sleep` unusable
/// on `any Clock<Duration>` existentials, so the generic call is boxed at
/// construction time.
struct ClockBox: Sendable {
    private let sleepForBoxed: @Sendable (Duration) async throws -> Void

    init<C: Clock & Sendable>(_ clock: C) where C.Instant.Duration == Duration {
        sleepForBoxed = { amount in
            try await clock.sleep(until: clock.now.advanced(by: amount), tolerance: nil)
        }
    }

    func sleep(for amount: Duration) async throws {
        try await sleepForBoxed(amount)
    }
}

private final class SubscriberHub: @unchecked Sendable {
    typealias SnapshotMap = [ProviderID: ProviderSnapshot]

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SnapshotMap>.Continuation] = [:]
    private var latest: SnapshotMap?

    func subscribe() -> AsyncStream<SnapshotMap> {
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

    func publish(_ snapshots: SnapshotMap) {
        lock.lock()
        latest = snapshots
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(snapshots)
        }
    }
}
