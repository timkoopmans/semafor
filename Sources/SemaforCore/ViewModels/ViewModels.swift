import Foundation

/// One metric's at-a-glance triplet for the popover (spec §9): latest
/// absolute value, learned "usual" median, fixed 0…2×-median series, and a
/// colour from the directional robust z — so the tile answers "fast or slow"
/// without reading the squiggle.
public struct MetricTileModel: Equatable, Sendable {
    public let valueText: String
    public let usualText: String
    /// Series normalized (÷ each sample's model median), clamped to 0…2.
    public let series: [Double]
    public let color: StatusItemModel.StatusColor
    /// Age of the measurement behind `valueText` ("1m ago", "5h ago"), so a
    /// stale-but-green tile can't be mistaken for a live reading.
    public let ageText: String?

    public init(
        valueText: String, usualText: String, series: [Double],
        color: StatusItemModel.StatusColor, ageText: String? = nil
    ) {
        self.valueText = valueText
        self.usualText = usualText
        self.series = series
        self.color = color
        self.ageText = ageText
    }
}

/// One day slot of the popover's 7-day token bar strip.
public struct DailyTokenBar: Equatable, Sendable {
    public let tokens: Int
    /// 0…1 normalised against the week's peak day.
    public let height: Double
    public let isToday: Bool

    public init(tokens: Int, height: Double, isToday: Bool) {
        self.tokens = tokens
        self.height = height
        self.isToday = isToday
    }
}

/// Everything the popover renders for one provider. Pure value type so all
/// copy is unit-testable without SwiftUI (spec §9).
public struct ProviderSectionModel: Equatable, Sendable {
    public struct WindowRow: Equatable, Sendable {
        public let label: String
        public let percentText: String
        public let barPercent: Double?
        public let resetsText: String
        public let paceText: String?
        public let dimmed: Bool
    }

    public let providerID: ProviderID
    public let displayName: String
    public let glyph: String
    public let rows: [WindowRow]
    public let headline: String?
    public let statusLine: String
    public let isStale: Bool
    public let verdictChip: String?
    public let chipColor: StatusItemModel.StatusColor
    /// Latest value + "usual" median + fixed 0…2×-median series (spec §9),
    /// colored by directional robust z against the same learned baseline the
    /// verdict ladder uses. nil when the provider has no `.ok` sample with
    /// that metric in the last 24 h.
    public let tileTTFT: MetricTileModel?
    public let tileTokPerSec: MetricTileModel?
    /// 7-day tokens-per-day strip (oldest → today); nil until any stored
    /// sample carries counts, so legacy days render nothing rather than a lie.
    public let tokenBars: [DailyTokenBar]?
    public let tokenCaption: String?
    public let measuredText: String?
    public let divergenceText: String?
    /// hal-only "serving X" line (spec §3.2), composed via
    /// `servingText(served:expectedModel:)`; nil hides the row elsewhere.
    public let servingText: String?
    /// hal-only "errors today: …" line (spec §3.3); nil when none in 24 h.
    public let errorLineText: String?
    public let errorLineIsAmber: Bool

    public init(
        snapshot: ProviderSnapshot,
        projections: [WindowName: BurnRateEstimator.Projection],
        now: Date,
        settings: AppSettings,
        pollInterval: TimeInterval,
        verdict: Verdict? = nil,
        latestProbe: ProbeSample? = nil,
        recentSamples: [ProbeSample] = [],
        divergenceText: String? = nil,
        measuredToday: Int = 0,
        servingText: String? = nil,
        errorLineText: String? = nil,
        errorLineIsAmber: Bool = false
    ) {
        self.servingText = servingText
        self.errorLineText = errorLineText
        self.errorLineIsAmber = errorLineIsAmber
        providerID = snapshot.providerID
        displayName = snapshot.providerID.displayName
        glyph = snapshot.providerID.menuGlyph
        let stale = now.timeIntervalSince(snapshot.fetchedAt) > 3 * pollInterval
        isStale = stale

        // Local binding so the map closure doesn't capture half-initialized self.
        let windowRows = snapshot.windows.map { window in
            WindowRow(
                label: Self.label(for: window.name),
                percentText: window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "–",
                barPercent: window.usedPercent,
                resetsText: Self.resetsText(resetsAt: window.resetsAt, now: now),
                paceText: Self.paceText(
                    for: window, now: now, settings: settings),
                dimmed: stale)
        }
        rows = windowRows

        // Longest window present wins the burn-rate headline.
        if snapshot.windows.contains(where: { $0.name == .sevenDay }),
           let projection = projections[.sevenDay]
        {
            headline = projection.headline
        } else if snapshot.windows.contains(where: { $0.name == .secondary }),
                  let projection = projections[.secondary]
        {
            headline = projection.headline
        } else {
            headline = nil
        }

        statusLine = Self.statusLine(for: snapshot, now: now)

        if let verdict, verdict.state != .ok {
            var parts = [VerdictEngine.stateLabel(verdict.state)]
            if let latestProbe, latestProbe.provider == snapshot.providerID {
                parts.append(Self.shortModel(latestProbe.model))
                let ttftText = latestProbe.ttft.map { "TTFT \(String(format: "%.1f", $0)) s" } ?? "–"
                let rateText = latestProbe.tokensPerSecond.map { Self.rateText($0) } ?? "–"
                parts.append(contentsOf: [ttftText, rateText])
            }
            verdictChip = parts.joined(separator: " · ")
            switch verdict.state {
            case .ok: chipColor = .green
            case .busy, .degraded: chipColor = .amber
            case .crawling, .limited: chipColor = .red
            case .unknown: chipColor = .grey
            }
        } else {
            verdictChip = nil
            chipColor = .green
        }

        measuredText = measuredToday > 0 ? "measured \(measuredToday) calls today" : nil
        self.divergenceText = divergenceText

        let usable = recentSamples.filter {
            $0.provider == snapshot.providerID && $0.outcome == .ok
                && $0.timestamp <= now
                && now.timeIntervalSince($0.timestamp) <= 24 * 3600
        }
        // Baseline pool: the store's whole window for this provider (same
        // history the verdict engine uses). Pooling only the last 24 h
        // starved the 6-hour segments on any quiet stretch and the tile then
        // printed the settings defaults as if they were learned (dogfood bug).
        let history = recentSamples.filter {
            $0.provider == snapshot.providerID && $0.outcome == .ok && $0.timestamp <= now
        }
        let baseline = BaselineEngine(thresholds: settings.thresholds)
        let thresholds = settings.thresholds
        tileTTFT = Self.metricTile(
            usable, baselinePool: history, value: \.ttft, now: now,
            provider: snapshot.providerID, baseline: baseline, thresholds: thresholds,
            fallbackMedian: settings.baselineDefaultTTFT, higherIsWorse: true)
        tileTokPerSec = Self.metricTile(
            usable, baselinePool: history, value: \.tokensPerSecond, now: now,
            provider: snapshot.providerID, baseline: baseline, thresholds: thresholds,
            fallbackMedian: settings.baselineDefaultTokPerSec, higherIsWorse: false)

        let strip = Self.tokenStrip(
            recentSamples, now: now, provider: snapshot.providerID, calendar: Calendar.current)
        tokenBars = strip?.0
        tokenCaption = strip?.1
    }

    /// Sums `.ok` sample tokens per local day over the last 7 days (fixed
    /// slots so the strip doesn't jiggle); nil when no sample carries a
    /// count or every day is zero.
    private static func tokenStrip(
        _ samples: [ProbeSample], now: Date, provider: ProviderID, calendar: Calendar
    ) -> ([DailyTokenBar], String)? {
        let today = calendar.startOfDay(for: now)
        var totals = [Int](repeating: 0, count: 7)
        var anyCount = false
        for sample in samples {
            guard sample.provider == provider, sample.outcome == .ok,
                  let tokens = sample.tokens, tokens >= 0
            else { continue }
            let day = calendar.startOfDay(for: sample.timestamp)
            guard let diff = calendar.dateComponents([.day], from: day, to: today).day,
                  (0...6).contains(diff)
            else { continue }
            totals[6 - diff] += tokens
            anyCount = true
        }
        guard anyCount, let peak = totals.max(), peak > 0 else { return nil }
        let bars = totals.enumerated().map { index, tokens in
            DailyTokenBar(tokens: tokens, height: Double(tokens) / Double(peak), isToday: index == 6)
        }
        let caption = "\(compactTokens(totals[6])) tok today · peak \(compactTokens(peak)) this week"
        return (bars, caption)
    }

    static func compactTokens(_ count: Int) -> String {
        let value: Double
        let suffix: String
        if count >= 1_000_000 {
            (value, suffix) = (Double(count) / 1_000_000, "M")
        } else if count >= 1_000 {
            (value, suffix) = (Double(count) / 1_000, "k")
        } else {
            return "\(count)"
        }
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }

    /// Value/median/z triplet for one metric. The series is normalized
    /// (÷ each sample's model median) and clamped to the tile's fixed
    /// 0…2×-median drawing domain, so height always means "vs usual".
    private static func metricTile(
        _ samples: [ProbeSample], baselinePool: [ProbeSample],
        value: KeyPath<ProbeSample, Double?>, now: Date,
        provider: ProviderID, baseline: BaselineEngine, thresholds: Thresholds,
        fallbackMedian: Double, higherIsWorse: Bool
    ) -> MetricTileModel? {
        let sorted = samples.filter { $0[keyPath: value] != nil }
            .sorted { $0.timestamp < $1.timestamp }
        guard let newest = sorted.last, let newestValue = newest[keyPath: value] else {
            return nil
        }
        let key = baseline.key(at: now, provider: provider, model: newest.model)
        let set = baseline.baseline(for: key, samples: baselinePool, now: now)
        let metric = higherIsWorse ? set.ttft : set.tokPerSec
        let median = metric.median > 0 ? metric.median : fallbackMedian
        let floor = higherIsWorse ? thresholds.madFloorTTFT : thresholds.madFloorTokPerSec

        // One-directional z (review rule): only the slow side counts — high
        // ttft, low tok/s — so a fast day never colours red.
        let z: Double
        if higherIsWorse, newestValue > median {
            z = (newestValue - median) / max(metric.mad, floor)
        } else if !higherIsWorse, newestValue < median {
            z = (median - newestValue) / max(metric.mad, floor)
        } else {
            z = 0
        }
        let color: StatusItemModel.StatusColor
        if z >= thresholds.zCrawl {
            color = .red
        } else if z >= thresholds.zWarn {
            color = .amber
        } else {
            color = .green
        }

        let series = Self.sparkValues(
            samples, pool: baselinePool, value: value, now: now, provider: provider,
            baseline: baseline, fallbackMedian: fallbackMedian
        ).map { min($0, 2) }

        let valueText: String
        let usualText: String
        if higherIsWorse {
            valueText = String(format: "%.1f s", newestValue)
            usualText = "usual " + String(format: "%.1f s", median)
        } else {
            valueText = Self.rateText(newestValue)
            usualText = "usual " + Self.rateNumber(median)
        }
        return MetricTileModel(
            valueText: valueText, usualText: usualText, series: series, color: color,
            ageText: Self.measurementAge(newest.timestamp, now: now))
    }

    /// "just now" / "N m ago" / "N h ago" — tiles draw the newest measurement
    /// from a 24 h window, so the age says how live that number really is.
    static func measurementAge(_ timestamp: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(timestamp))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds) / 60)m ago" }
        return "\(Int(seconds) / 3600)h ago"
    }

    /// hal serving line (spec §3.2 + swap warning): the vLLM box serves one
    /// model at a time, so any pick but the configured one is flagged.
    public static func servingText(served: String?, expectedModel: String) -> String {
        guard let served else { return "serving unknown" }
        guard served != expectedModel else { return "serving \(served)" }
        return "serving \(served) · not \(expectedModel) ⚠"
    }

    /// hal error line (spec §3.3): grouped counts of the last 24 h's scanned
    /// API errors, busiest code first ("2× 429 · 1× 500"), plus the newest
    /// record's age from the shared humanizer. nil when the window is empty;
    /// amber on rate-limit/overload/server codes, grey on request-shape 4xx.
    public static func halErrorLine(
        records: [HalErrorRecord], now: Date, calendar: Calendar
    ) -> (text: String, amber: Bool)? {
        let cutoff = calendar.date(byAdding: .day, value: -1, to: now)
            ?? now.addingTimeInterval(-86_400)
        let window = records.filter { $0.at >= cutoff }
        guard !window.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for record in window { counts[record.code, default: 0] += 1 }
        let groups = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
            .map { "\($0.value)× \($0.key)" }
        let newest = window.max { $0.at < $1.at }!  // non-empty window
        let amberCodes: Set<Int> = [429, 500, 502, 503, 504, 529]
        let amber = window.contains { amberCodes.contains($0.code) }
        let text = "errors today: \(groups.joined(separator: " · "))"
            + " · last \(measurementAge(newest.at, now: now))"
        return (text: text, amber: amber)
    }

    /// Per-model, ÷ the current segment's learned median so a provider that
    /// is simply "twice as slow as usual" draws a visible rise regardless of
    /// absolute scale (spec §9 sparklines).
    private static func sparkValues(
        _ samples: [ProbeSample], pool: [ProbeSample],
        value: KeyPath<ProbeSample, Double?>,
        now: Date, provider: ProviderID, baseline: BaselineEngine,
        fallbackMedian: Double
    ) -> [Double] {
        let sorted = samples.filter { $0[keyPath: value] != nil }.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }
        var medians: [String: Double] = [:]
        let normalized = sorted.map { sample -> Double in
            let median: Double
            if let cached = medians[sample.model] {
                median = cached
            } else {
                let key = baseline.key(at: now, provider: provider, model: sample.model)
                let set = baseline.baseline(for: key, samples: pool, now: now)
                let metric = value == \ProbeSample.tokensPerSecond ? set.tokPerSec : set.ttft
                median = metric.median > 0 ? metric.median : fallbackMedian
                medians[sample.model] = median
            }
            return (sample[keyPath: value] ?? 0) / median
        }
        guard normalized.count > 48 else { return normalized }
        let step = (normalized.count + 47) / 48
        return stride(from: 0, to: normalized.count, by: step).map { normalized[$0] }
    }

    /// "claude-opus-5-5" → "Opus 5.5"; unknown slugs get light prettifying
    /// only ("gpt-6-astra" → "GPT 6 Astra").
    static func shortModel(_ model: String) -> String {
        var slug = model.lowercased()
        for prefix in ["claude-", "anthropic-"] where slug.hasPrefix(prefix) {
            slug = String(slug.dropFirst(prefix.count))
        }
        var tokens = slug.split(separator: "-").map(String.init)
        // Collapse trailing numeric runs: ["opus","5","5"] → ["opus","5.5"].
        if let firstNumber = tokens.firstIndex(where: { Int($0) != nil }) {
            let numbers = tokens[firstNumber...].filter { Int($0) != nil }
            if numbers.count > 1, numbers.count == tokens.count - firstNumber {
                tokens = Array(tokens[..<firstNumber]) + [numbers.joined(separator: ".")]
            }
        }
        return tokens.map { token in
            if Int(token) != nil { return token }
            if token == "gpt" { return "GPT" }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        .joined(separator: " ")
    }

    static func rateText(_ rate: Double) -> String {
        "\(rateNumber(rate)) tok/s"
    }

    static func rateNumber(_ rate: Double) -> String {
        rate == rate.rounded() && abs(rate) < 1000
            ? String(format: "%.0f", rate) : String(format: "%.1f", rate)
    }

    // MARK: - Copy

    static func label(for name: WindowName) -> String {
        switch name {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        }
    }

    static func resetsText(resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return "—" }
        let total = Int(resetsAt.timeIntervalSince(now))
        if total < 60 { return "resetting…" }  // imminent or past: window is turning over
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }

    static func paceText(
        for window: UsageWindow, now: Date, settings: AppSettings
    ) -> String? {
        switch BurnRateEstimator.pace(
            usedPercent: window.usedPercent,
            windowSeconds: window.windowSeconds,
            resetsAt: window.resetsAt,
            now: now,
            threshold: settings.paceDeltaPoints
        ) {
        case .aheadOfPace(let delta):
            return "ahead of pace (+\(Int(delta.rounded())) pts)"
        case .ok, .notEnoughData:
            return nil
        }
    }

    static func statusLine(for snapshot: ProviderSnapshot, now: Date) -> String {
        let base: String
        switch snapshot.lastError {
        case nil:
            return ""
        case .auth(.missingCredentials):
            base = "Not signed in — run `\(cliName(snapshot.providerID))` once"
        case .auth(.expiredCredentials):
            base = "Token expired — run `\(cliName(snapshot.providerID))` once"
        case .network:
            base = "Network unreachable"
        case .http(let status):
            base = "Provider API error (\(status))"
        case .decoding:
            base = "Unexpected provider response"
        }
        // The snapshot is the last *successful-or-failed* poll; say how old
        // that failure is so a 429 from the last poll cycle isn't mistaken
        // for something happening right now.
        return "\(base) · \(measurementAge(snapshot.fetchedAt, now: now))"
    }

    private static func cliName(_ id: ProviderID) -> String {
        switch id {
        case .claude: return "claude"
        case .codex: return "codex"
        case .hal: return "hal"
        }
    }
}

/// Menu-bar item copy + color, decided from the worst window across all
/// providers (spec §9: one glance tells you the worst situation).
public enum StatusItemModel {
    public enum StatusColor: Equatable, Sendable {
        case green, amber, red, grey
    }

    public struct Result: Equatable, Sendable {
        public let title: String
        public let color: StatusColor
    }

    public static func title(
        for snapshots: [ProviderID: ProviderSnapshot],
        pollInterval: TimeInterval,
        now: Date,
        verdicts: [ProviderID: Verdict] = [:]
    ) -> Result {
        // Codex first in the preference list ⇒ it wins ties: replace only on
        // a strictly greater percent (max(by:) ties are unspecified).
        let preference: [ProviderID] = [.codex, .claude]
        let worst = preference.compactMap { provider -> (ProviderID, Double)? in
            guard let maxPercent = snapshots[provider]?.windows.compactMap(\.usedPercent).max()
            else { return nil }
            return (provider, maxPercent)
        }
        guard !worst.isEmpty else {
            let leader = worstPercents(snapshots) // nil-safe for the colour ladder
            return Result(title: "✳ –",
                          color: color(for: snapshots, worst: leader, verdicts: verdicts,
                                       forceNoDataGreyWhenQuiet: verdicts.isEmpty))
        }
        var leader = worst[0]
        for candidate in worst.dropFirst() where candidate.1 > leader.1 {
            leader = candidate
        }

        return Result(
            title: "\(leader.0.menuGlyph) \(Int(leader.1.rounded()))%",
            color: color(for: snapshots, worst: leader.1, verdicts: verdicts,
                         forceNoDataGreyWhenQuiet: false))
    }

    private static func worstPercents(
        _ snapshots: [ProviderID: ProviderSnapshot]
    ) -> Double? {
        snapshots.values.flatMap(\.windows).compactMap(\.usedPercent).max()
    }

    /// Verdicts outrank percents: crawling/limited ⇒ red; degraded/busy ⇒
    /// amber; unknown or any provider error ⇒ grey; otherwise the percent
    /// ladder (≥ 98 red, ≥ 80 amber) and green. With no snapshots and no
    /// verdicts, grey ("unknown ≠ all-clear", spec §8.2/§9).
    private static func color(
        for snapshots: [ProviderID: ProviderSnapshot],
        worst: Double?,
        verdicts: [ProviderID: Verdict],
        forceNoDataGreyWhenQuiet: Bool
    ) -> StatusColor {
        let states = Set(verdicts.values.map(\.state))
        if states.contains(.crawling) || states.contains(.limited) || (worst ?? 0) >= 98 {
            return .red
        }
        if states.contains(.degraded) || states.contains(.busy) || (worst ?? 0) >= 80 {
            return .amber
        }
        if states.contains(.unknown) || snapshots.values.contains(where: { $0.lastError != nil }) {
            return .grey
        }
        if snapshots.isEmpty && forceNoDataGreyWhenQuiet { return .grey }
        return .green
    }
}
