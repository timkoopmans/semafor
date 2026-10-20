import Foundation

/// Everything the verdict ladder looks at for one provider (spec §8.2).
public struct VerdictInput: Sendable {
    public let snapshot: ProviderSnapshot
    /// Any model, any age — the engine applies the freshness rule itself.
    public let probes: [ProbeSample]
    public let controls: [ControlSample]
    public let projections: [WindowName: BurnRateEstimator.Projection]
    public let paceStatuses: [WindowName: BurnRateEstimator.PaceStatus]
    public let capacityEvents: [CapacityEvent]

    public init(
        snapshot: ProviderSnapshot,
        probes: [ProbeSample],
        controls: [ControlSample],
        projections: [WindowName: BurnRateEstimator.Projection] = [:],
        paceStatuses: [WindowName: BurnRateEstimator.PaceStatus] = [:],
        capacityEvents: [CapacityEvent] = []
    ) {
        self.snapshot = snapshot
        self.probes = probes
        self.controls = controls
        self.projections = projections
        self.paceStatuses = paceStatuses
        self.capacityEvents = capacityEvents
    }
}

public enum VerdictEngine {
    private static let capacityWindow: TimeInterval = 600

    /// First hit wins, in state-priority order (spec §8.2). Probe rules only
    /// count samples inside `thresholds.sampleRecency` (freshness rule).
    public static func verdict(
        for id: ProviderID,
        input: VerdictInput,
        baseline: BaselineEngine,
        thresholds: Thresholds,
        now: Date
    ) -> Verdict {
        var reasons: [VerdictReason] = []

        // 1. UNKNOWN — dead auth, or measuring while the network looks broken.
        if case .auth(let reason)? = input.snapshot.lastError {
            return Verdict(
                provider: id, state: .unknown,
                reasons: [VerdictReason(code: "auth", detail: reason.rawValue)],
                computedAt: now)
        }
        let measuring = input.probes.contains {
            $0.provider == id && $0.timestamp <= now
                && now.timeIntervalSince($0.timestamp) <= thresholds.sampleRecency
        }
        // Control evidence must be as fresh as probe evidence (review C1):
        // stale bad controls prove nothing about *now*.
        let freshControls = input.controls
            .filter { $0.provider == id && $0.timestamp <= now
                && now.timeIntervalSince($0.timestamp) <= thresholds.sampleRecency }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(thresholds.controlRecentCount)
        if measuring, !freshControls.isEmpty,
           freshControls.allSatisfy({ $0.isBad(threshold: thresholds.controlBadLatency) })
        {
            return Verdict(
                provider: id, state: .unknown,
                reasons: [VerdictReason(code: "control", detail: "control probe down/slow")],
                computedAt: now)
        }

        // 2. LIMITED — windows pinned near the cap, or fresh capacity events.
        for window in input.snapshot.windows
        where (window.usedPercent ?? 0) >= thresholds.limitedPercent {
            reasons.append(VerdictReason(
                code: "window_pct",
                detail: "\(window.name.rawValue) at \(Int(window.usedPercent ?? 0))%"))
        }
        for event in input.capacityEvents
        where event.provider == id
            && ["rateLimit429", "planLimit"].contains(event.kind.rawValue)
            && now.timeIntervalSince(event.at) <= capacityWindow
            && event.at <= now
        {
            reasons.append(VerdictReason(
                code: "capacity_429", detail: event.detail ?? event.kind.rawValue))
        }
        if !reasons.isEmpty {
            return Verdict(provider: id, state: .limited, reasons: reasons, computedAt: now)
        }

        // 3/4. CRAWLING / DEGRADED — worst model's trailing run of slow calls.
        if let slow = slowVerdict(for: id, input: input, baseline: baseline,
                                  thresholds: thresholds, now: now) {
            return slow
        }

        // 5. BUSY.
        var busyReasons: [VerdictReason] = []
        for window in input.snapshot.windows
        where (window.usedPercent ?? 0) >= thresholds.busyPercent {
            busyReasons.append(VerdictReason(
                code: "busy_pct",
                detail: "\(window.name.rawValue) at \(Int(window.usedPercent ?? 0))%"))
        }
        if let ahead = input.paceStatuses.values.first(where: {
            if case .aheadOfPace = $0 { return true } else { return false }
        }), case .aheadOfPace(let delta) = ahead {
            busyReasons.append(VerdictReason(
                code: "pace", detail: "burning \(String(format: "%.0f", delta)) pts ahead"))
        }
        if !busyReasons.isEmpty {
            return Verdict(provider: id, state: .busy, reasons: busyReasons, computedAt: now)
        }

        // 6. OK.
        return Verdict(provider: id, state: .ok, reasons: [], computedAt: now)
    }

    // MARK: - Probe rules

    private static func slowVerdict(
        for id: ProviderID,
        input: VerdictInput,
        baseline: BaselineEngine,
        thresholds: Thresholds,
        now: Date
    ) -> Verdict? {
        let fresh = input.probes.filter {
            $0.provider == id && $0.outcome == .ok && $0.timestamp <= now
                && now.timeIntervalSince($0.timestamp) <= thresholds.sampleRecency
        }
        // Review I2: z-comparison baselines come only from *outside* the
        // recency window, so a sustained crawl can't move the learned
        // median onto itself and certify itself normal.
        let history = input.probes.filter {
            $0.provider == id && now.timeIntervalSince($0.timestamp) > thresholds.sampleRecency
        }
        var worst: (state: ProviderState, reason: VerdictReason)?
        for (_, group) in Dictionary(grouping: fresh, by: \.model) {
            let sorted = group.sorted { $0.timestamp < $1.timestamp }
            guard sorted.count >= thresholds.consecutiveN else { continue }
            let tail = Array(sorted.suffix(thresholds.consecutiveN))
            let scored = tail.map { slowScore($0, model: $0.model, id: id,
                                              probes: history,
                                              baseline: baseline, thresholds: thresholds, now: now) }

            let allCrawl = scored.allSatisfy { ($0.ttftZ > thresholds.zCrawl || ($0.tokZ ?? -1) > thresholds.zCrawl) }
            let allWarn = scored.allSatisfy { ($0.ttftZ > thresholds.zWarn || ($0.tokZ ?? -1) > thresholds.zWarn) }
            guard allCrawl || allWarn else { continue }

            // Cite the single worst sample/metric.
            var bestMetric = scored[0]
            for score in scored {
                if max(score.ttftZ, score.tokZ ?? -1) > max(bestMetric.ttftZ, bestMetric.tokZ ?? -1) {
                    bestMetric = score
                }
            }
            let state: ProviderState = allCrawl ? .crawling : .degraded
            let reason: VerdictReason
            if bestMetric.ttftZ >= (bestMetric.tokZ ?? -1) {
                reason = VerdictReason(
                    code: "ttft_z",
                    detail: "z=\(fmt(bestMetric.ttftZ)) · TTFT \(fmt(bestMetric.value))s vs "
                        + "\(fmt(bestMetric.median))s median · \(bestMetric.model)")
            } else {
                reason = VerdictReason(
                    code: "toks_z",
                    detail: "z=\(fmt(bestMetric.tokZ ?? 0)) · \(fmt(bestMetric.value)) tok/s vs "
                        + "\(fmt(bestMetric.median)) median · \(bestMetric.model)")
            }
            if worst == nil || state > worst!.state {
                worst = (state, reason)
            }
        }
        guard let worst else { return nil }
        return Verdict(provider: id, state: worst.state, reasons: [worst.reason], computedAt: now)
    }

    /// One-directional z: only values worse than the median count (slow TTFT
    /// = higher, slow throughput = lower); `nil` metric ⇒ not slow via it.
    private struct SampleScore {
        let model: String
        let value: Double
        let median: Double
        let ttftZ: Double
        let tokZ: Double?
    }

    private static func slowScore(
        _ sample: ProbeSample, model: String, id: ProviderID,
        probes: [ProbeSample], baseline: BaselineEngine,
        thresholds: Thresholds, now: Date
    ) -> SampleScore {
        let key = baseline.key(at: sample.timestamp, provider: id, model: model)
        let set = baseline.baseline(for: key, samples: probes, now: now)
        let ttftZ: Double
        if let ttft = sample.ttft, ttft > set.ttft.median {
            ttftZ = baseline.z(ttft, metric: set.ttft, floor: thresholds.madFloorTTFT)
        } else {
            ttftZ = 0
        }
        let tokZ: Double?
        if let rate = sample.tokensPerSecond, rate < set.tokPerSec.median {
            tokZ = baseline.z(rate, metric: set.tokPerSec, floor: thresholds.madFloorTokPerSec)
        } else {
            tokZ = nil
        }
        let value = ttftZ >= (tokZ ?? -1) ? (sample.ttft ?? 0) : (sample.tokensPerSecond ?? 0)
        let median = ttftZ >= (tokZ ?? -1) ? set.ttft.median : set.tokPerSec.median
        return SampleScore(model: model, value: value, median: median, ttftZ: ttftZ, tokZ: tokZ)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: - Labels and divergence

    public static func stateLabel(_ state: ProviderState) -> String {
        switch state {
        case .ok: return "OK"
        case .busy: return "Busy"
        case .degraded: return "Degraded"
        case .crawling: return "Crawling"
        case .limited: return "Limited"
        case .unknown: return "Unknown"
        }
    }

    /// "Their status page is green, ours is crawling" banner (spec §8.2);
    /// nil when nothing is troubled, any troubled provider's page is not
    /// explicitly operational, or a control reason blames our network.
    public static func divergence(
        verdicts: [ProviderID: Verdict],
        statuses: [ProviderID: StatusPageState],
        latestProbes: [ProbeSample]
    ) -> String? {
        let troubled = verdicts.values.filter {
            [.degraded, .crawling, .limited].contains($0.state)
        }
        guard !troubled.isEmpty else { return nil }
        for verdict in troubled {
            guard statuses[verdict.provider] == .operational else { return nil }
            guard !verdict.reasons.contains(where: { $0.code == "control" }) else { return nil }
        }
        let entries = troubled
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
            .map { entryLine($0, latestProbes: latestProbes) }
            .joined(separator: ", ")
        return "Status pages: ✅ operational · ours: \(entries)"
    }

    private static func entryLine(_ verdict: Verdict, latestProbes: [ProbeSample]) -> String {
        let name = verdict.provider.rawValue.prefix(1).uppercased()
            + verdict.provider.rawValue.dropFirst()
        var line = "\(name) \(stateLabel(verdict.state))"
        guard verdict.state == .degraded || verdict.state == .crawling,
              let newest = latestProbes
                .filter({ $0.provider == verdict.provider && $0.outcome == .ok })
                .max(by: { $0.timestamp < $1.timestamp })
        else { return line }
        let ttftText = newest.ttft.map { "TTFT \(String(format: "%.1f", $0)) s" } ?? "–"
        let rateText: String
        if let rate = newest.tokensPerSecond {
            let number = rate == rate.rounded() && abs(rate) < 1000
                ? String(format: "%.0f", rate) : String(format: "%.1f", rate)
            rateText = "\(number) tok/s"
        } else {
            rateText = "–"
        }
        line += " (\(newest.model) · \(ttftText) · \(rateText))"
        return line
    }
}
