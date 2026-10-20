import Foundation
import Testing
@testable import SemaforCore

/// The verdict ladder (spec §8.2): first hit wins — UNKNOWN → LIMITED →
/// CRAWLING/DEGRADED → BUSY → OK, with the freshness rule and the
/// status-page divergence banner.
struct VerdictEngineTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }
    private var thresholds: Thresholds {
        Thresholds(
            zWarn: 3, zCrawl: 6, consecutiveN: 3, busyPercent: 80, limitedPercent: 98,
            paceDeltaPoints: 15, baselineMinSamples: 20,
            baselineDefaultTTFT: 8, baselineDefaultTokPerSec: 20)
    }
    private var baseline: BaselineEngine {
        BaselineEngine(thresholds: thresholds, calendar: calendar)
    }

    /// Mon 2026-10-19 10:00 UTC; samples every 60 s keep one segment.
    private let segmentStart = Date(timeIntervalSince1970: 1_760_860_800)
    private var now: Date { segmentStart.addingTimeInterval(40 * 60) }

    private func sample(
        at offset: TimeInterval, ttft: Double?, tokPerSec: Double?,
        model: String = "claude-opus-5-5", provider: ProviderID = .claude,
        outcome: ProbeOutcome = .ok
    ) -> ProbeSample {
        ProbeSample(
            provider: provider, model: model, sessionKey: "f#\(offset)-\(UUID().uuidString)",
            ttft: ttft, duration: 5, tokensPerSecond: tokPerSec,
            outcome: outcome, timestamp: segmentStart.addingTimeInterval(offset))
    }

    /// `count` learned-baseline fillers at ttft 2 / tok/s 80, at 60 s steps
    /// starting at `firstOffset`.
    private func fast(_ count: Int, firstOffset: TimeInterval = 0, model: String = "claude-opus-5-5", provider: ProviderID = .claude) -> [ProbeSample] {
        (0..<count).map {
            sample(at: firstOffset + Double($0) * 60, ttft: 2.0, tokPerSec: 80,
                   model: model, provider: provider)
        }
    }

    private func snapshot(
        _ id: ProviderID = .claude, percents: [Double] = [], error: ProviderError? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            windows: percents.enumerated().map { index, percent in
                UsageWindow(
                    name: index == 0 ? .primary : .secondary, usedPercent: percent,
                    windowSeconds: 18_000, resetsAt: nil, fetchedAt: now)
            },
            fetchedAt: now, lastError: error)
    }

    /// hal sample: the OpenCode db never records a first-token time, so
    /// hal probes carry ttft nil by construction.
    private func halSample(
        at offset: TimeInterval, tokPerSec: Double?, model: String = "qwen3.8-flash"
    ) -> ProbeSample {
        ProbeSample(
            provider: .hal, model: model, sessionKey: "opencode.db#\(offset)-\(UUID().uuidString)",
            ttft: nil, duration: 5, tokensPerSecond: tokPerSec,
            outcome: .ok, timestamp: segmentStart.addingTimeInterval(offset))
    }

    /// `count` hal fillers at tok/s 80, at 60 s steps starting at
    /// `firstOffset`.
    private func halFast(
        _ count: Int, firstOffset: TimeInterval = 0, model: String = "qwen3.8-flash"
    ) -> [ProbeSample] {
        (0..<count).map {
            halSample(at: firstOffset + Double($0) * 60, tokPerSec: 80, model: model)
        }
    }

    /// 24 hal history samples outside the recency window at tok/s 78/82 ⇒
    /// learned median 80, MAD 2.
    private func halHistory(model: String = "qwen3.8-flash") -> [ProbeSample] {
        (0..<24).map {
            halSample(at: -((40.0 + Double($0) * 2) * 60),
                      tokPerSec: $0.isMultiple(of: 2) ? 78 : 82, model: model)
        }
    }

    private func controls(_ latencies: [Double?], id: ProviderID = .claude) -> [ControlSample] {
        latencies.enumerated().map { index, latency in
            ControlSample(
                provider: id, latency: latency,
                timestamp: now.addingTimeInterval(-300 + Double(index) * 60))
        }
    }

    private func input(
        _ id: ProviderID = .claude,
        probes: [ProbeSample] = [], controls controlSamples: [ControlSample] = [],
        percents: [Double] = [], error: ProviderError? = nil,
        pace: [WindowName: BurnRateEstimator.PaceStatus] = [:],
        capacity: [CapacityEvent] = []
    ) -> VerdictInput {
        VerdictInput(
            snapshot: snapshot(id, percents: percents, error: error),
            probes: probes, controls: controlSamples,
            projections: [:], paceStatuses: pace, capacityEvents: capacity)
    }

    private func verdict(
        _ id: ProviderID = .claude, probes: [ProbeSample] = [],
        controls controlSamples: [ControlSample] = [], percents: [Double] = [],
        error: ProviderError? = nil,
        pace: [WindowName: BurnRateEstimator.PaceStatus] = [:],
        capacity: [CapacityEvent] = []
    ) -> Verdict {
        VerdictEngine.verdict(
            for: id,
            input: input(id, probes: probes, controls: controlSamples, percents: percents,
                         error: error, pace: pace, capacity: capacity),
            baseline: baseline, thresholds: thresholds, now: now)
    }

    // MARK: - Rule table

    @Test func authErrorIsUnknownAboveEverything() {
        let slow = fast(24) + [sample(at: 25 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 26 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 27 * 60, ttft: 21, tokPerSec: 9)]
        let result = verdict(probes: slow, percents: [99], error: .auth(.expiredCredentials))
        #expect(result.state == .unknown)
        #expect(result.reasons.map(\.code) == ["auth"])
    }

    @Test func badControlsWhileMeasuringIsUnknown() {
        let result = verdict(
            probes: fast(24, firstOffset: 36 * 60),  // fresh within 40-min now
            controls: controls([nil, nil, nil]))
        #expect(result.state == .unknown)
        #expect(result.reasons.map(\.code) == ["control"])
    }

    @Test func staleSamplesWithBadControlsAreNotUnknown() {
        // Freshness rule: controls only explain away live measurement.
        let result = verdict(
            probes: fast(24, firstOffset: -60 * 60),  // an hour old
            controls: controls([nil, nil, nil]))
        #expect(result.state == .ok)
    }

    @Test func goodControlsNeverTriggerUnknown() {
        let result = verdict(probes: fast(24, firstOffset: 36 * 60), controls: controls([0.4, 0.5, nil]))
        #expect(result.state == .ok)
    }

    @Test func staleControlEvidenceCannotBlameTheNetwork() {
        // Review C1: control evidence must be as fresh as probe evidence, or
        // an old VPN flake + disabled control toggle pins UNKNOWN forever.
        let eightHoursAgo = now.addingTimeInterval(-8 * 3600)
        let staleBad = [0.0, 1.0, 2.0].map { index in
            ControlSample(provider: .claude, latency: nil,
                          timestamp: eightHoursAgo.addingTimeInterval(Double(index) * 60))
        }
        let result = verdict(probes: fast(24, firstOffset: 36 * 60), controls: staleBad)
        #expect(result.state == .ok)
    }

    @Test func windowNearCapIsLimitedAndBeatsCrawling() {
        let slow = fast(24) + [sample(at: 25 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 26 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 27 * 60, ttft: 21, tokPerSec: 9)]
        let result = verdict(probes: slow, percents: [98])
        #expect(result.state == .limited)
        #expect(result.reasons.first?.code == "window_pct")
    }

    @Test func recentCapacityEventIsLimited() {
        let event = CapacityEvent(provider: .claude, kind: .rateLimit429, detail: "429",
                                  at: now.addingTimeInterval(-300))
        let result = verdict(capacity: [event])
        #expect(result.state == .limited)
        #expect(result.reasons.map(\.code).contains("capacity_429"))
    }

    @Test func staleCapacityEventDoesNotCount() {
        let event = CapacityEvent(provider: .claude, kind: .overloaded, detail: nil,
                                  at: now.addingTimeInterval(-900))
        #expect(verdict(capacity: [event]).state == .ok)
    }

    @Test func trailingSlowRunCrawls() {
        let slow = fast(24) + [sample(at: 25 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 26 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 27 * 60, ttft: 21, tokPerSec: 9)]
        let result = verdict(probes: slow)
        #expect(result.state == .crawling)
        #expect(["ttft_z", "toks_z"].contains(result.reasons.first?.code))
        #expect(result.reasons.first?.detail.contains("claude-opus-5-5") == true)
        #expect(result.reasons.first?.detail.contains("z=") == true)
    }

    @Test func sustainedCrawlCannotCertifyItselfNormal() {
        // Review I2: the z-comparison baseline must exclude the recency
        // window, or ≥ 50 % slow samples in a segment flip the learned
        // median onto the crawl itself and the verdict reads .ok.
        // (Offsets are relative to segmentStart 10:00; now = 10:40,
        // recency 30 min ⇒ history sits before 10:10.)
        let fastHistory = (0..<20).map {
            sample(at: -((40.0 + Double($0) * 2) * 60), ttft: 2.0, tokPerSec: 80)
        }
        let slowFresh = (0..<24).map {
            sample(at: 37 * 60 - Double($0) * 40, ttft: 21, tokPerSec: 9)
        }
        let result = verdict(probes: fastHistory + slowFresh)
        #expect(result.state == .crawling)
    }

    @Test func moderateSlowRunDegrades() {
        // History baseline (outside the recency window): tok/s 78/82 ⇒
        // median 80, MAD 2; a 71 tok/s tail gives z = 9/2 = 4.5 — over
        // zWarn, under zCrawl. ttft stays quiet (z 0.8).
        var fillers: [ProbeSample] = []
        for i in 0..<24 {
            fillers.append(sample(at: -((40.0 + Double(i) * 2) * 60), ttft: 2.0, tokPerSec: i.isMultiple(of: 2) ? 78 : 82))
        }
        let degraded = fillers + [sample(at: 37 * 60, ttft: 2.2, tokPerSec: 71),
                                  sample(at: 38 * 60, ttft: 2.2, tokPerSec: 71),
                                  sample(at: 39 * 60, ttft: 2.2, tokPerSec: 71)]
        let result = verdict(probes: degraded)
        #expect(result.state == .degraded)
        #expect(result.reasons.first?.code == "toks_z")
    }

    @Test func flappingGuardNeedsFullTrailingRun() {
        // Two slow among fast traffic ⇒ no trigger.
        let mixed = fast(24) + [sample(at: 25 * 60, ttft: 21, tokPerSec: 9),
                                sample(at: 26 * 60, ttft: 21, tokPerSec: 9)]
        #expect(verdict(probes: mixed).state == .ok)
        // Interleaved fast sample in the trailing window also blocks.
        let flap = fast(24) + [sample(at: 25 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 26 * 60, ttft: 2.0, tokPerSec: 80),
                               sample(at: 27 * 60, ttft: 21, tokPerSec: 9)]
        #expect(verdict(probes: flap).state == .ok)
    }

    @Test func staleSlowSamplesAreQuiet() {
        // Freshness rule: the slow tail sits outside the recency window.
        let slow = fast(24, firstOffset: -90 * 60) + [
            sample(at: -65 * 60, ttft: 21, tokPerSec: 9),
            sample(at: -64 * 60, ttft: 21, tokPerSec: 9),
            sample(at: -63 * 60, ttft: 21, tokPerSec: 9),
        ]
        #expect(verdict(probes: slow).state == .ok)
    }

    @Test func timeoutSamplesDoNotFeedProbeRulesButKeepMeasuring() {
        // All-timeout tail: no z-rules (only .ok feeds), but ≥1 fresh sample
        // means we ARE measuring ⇒ bad controls ⇒ UNKNOWN(control).
        let timeouts = (0..<3).map {
            sample(at: 37 * 60 + Double($0) * 60, ttft: nil, tokPerSec: nil, outcome: .timeout)
        }
        let result = verdict(probes: fast(24, firstOffset: 30 * 60) + timeouts,
                             controls: controls([nil, nil, nil]))
        #expect(result.state == .unknown)
        #expect(result.reasons.map(\.code) == ["control"])
    }

    @Test func busyFromWindowOrPace() {
        let byWindow = verdict(probes: fast(24), percents: [85])
        #expect(byWindow.state == .busy)
        #expect(byWindow.reasons.first?.code == "busy_pct")

        let byPace = verdict(probes: fast(24), pace: [.primary: .aheadOfPace(deltaPoints: 20)])
        #expect(byPace.state == .busy)
        #expect(byPace.reasons.first?.code == "pace")
    }

    @Test func quietProviderIsOk() {
        let result = verdict(probes: fast(24, firstOffset: 36 * 60), controls: controls([0.4, 0.4, 0.4]))
        #expect(result.state == .ok)
        #expect(result.reasons.isEmpty)
    }

    @Test func stateLabels() {
        #expect(VerdictEngine.stateLabel(.ok) == "OK")
        #expect(VerdictEngine.stateLabel(.busy) == "Busy")
        #expect(VerdictEngine.stateLabel(.degraded) == "Degraded")
        #expect(VerdictEngine.stateLabel(.crawling) == "Crawling")
        #expect(VerdictEngine.stateLabel(.limited) == "Limited")
        #expect(VerdictEngine.stateLabel(.unknown) == "Unknown")
    }

    @Test func worstModelWins() {
        // Opus fine, sonnet crawling ⇒ verdict cites sonnet.
        let opus = fast(24, firstOffset: 12 * 60)
        let sonnetSlow = (0..<24).map {
            sample(at: 12 * 60 + Double($0) * 60, ttft: 1.0, tokPerSec: 90, model: "claude-sonnet-5-5")
        } + [
            sample(at: 37 * 60, ttft: 30, tokPerSec: 5, model: "claude-sonnet-5-5"),
            sample(at: 38 * 60, ttft: 30, tokPerSec: 5, model: "claude-sonnet-5-5"),
            sample(at: 39 * 60, ttft: 30, tokPerSec: 5, model: "claude-sonnet-5-5"),
        ]
        let result = verdict(probes: opus + sonnetSlow)
        #expect(result.state == .crawling)
        #expect(result.reasons.first?.detail.contains("claude-sonnet-5-5") == true)
    }

    // MARK: - Divergence banner

    @Test func badControlsSuppressTheBanner() {
        // Slow samples + all-bad controls ⇒ the verdict itself is UNKNOWN,
        // so there is nothing to banner about.
        let slow = fast(24) + [sample(at: 37 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 38 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 39 * 60, ttft: 21, tokPerSec: 9)]
        let result = verdict(probes: slow, controls: controls([nil, nil, nil]))
        #expect(result.state == .unknown)
        #expect(VerdictEngine.divergence(
            verdicts: [.claude: result], statuses: [.claude: .operational],
            latestProbes: slow) == nil)
    }

    @Test func nonOperationalStatusSuppressesTheBanner() {
        let slow = fast(24) + [sample(at: 37 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 38 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 39 * 60, ttft: 21, tokPerSec: 9)]
        let result = verdict(probes: slow, controls: controls([0.4, 0.4, 0.4]))
        #expect(result.state == .crawling)
        // Their status page admits trouble ⇒ no "they say all ok" claim.
        #expect(VerdictEngine.divergence(
            verdicts: [.claude: result], statuses: [.claude: .degraded],
            latestProbes: slow) == nil)
        #expect(VerdictEngine.divergence(
            verdicts: [.claude: result], statuses: [:], latestProbes: slow) == nil)
    }

    @Test func goodControlsAndOperationalStatusProduceBanner() throws {
        let slow = fast(24) + [sample(at: 37 * 60, ttft: 21.4, tokPerSec: 9),
                               sample(at: 38 * 60, ttft: 21.4, tokPerSec: 9),
                               sample(at: 39 * 60, ttft: 21.4, tokPerSec: 9)]
        let result = verdict(probes: slow, controls: controls([0.4, 0.4, 0.4]))
        let banner = VerdictEngine.divergence(
            verdicts: [.claude: result], statuses: [.claude: .operational],
            latestProbes: slow)
        let text = try #require(banner)
        #expect(text.contains("✅ operational"))
        #expect(text.contains("Claude Crawling"))
        #expect(text.contains("claude-opus-5-5") || text.contains("21.4"))
    }

    // MARK: - hal (local Qwen box)

    @Test func halNeverSeesControlOrLimitVerdicts() {
        // hal has no limits endpoint (fetchLimits returns []) and never gets
        // control samples, so with a fresh measuring stream and no windows
        // it can never land on UNKNOWN(control), LIMITED, or BUSY.
        let result = verdict(.hal, probes: halFast(24, firstOffset: 36 * 60))
        #expect(result.state == .ok)
        #expect(result.reasons.isEmpty)

        // A slow tail with zero control evidence reads as slow, not as our
        // network and not as quota either.
        let slow = halHistory() + [halSample(at: 37 * 60, tokPerSec: 40),
                                   halSample(at: 38 * 60, tokPerSec: 40),
                                   halSample(at: 39 * 60, tokPerSec: 40)]
        let troubled = verdict(.hal, probes: slow)
        #expect(troubled.state != .unknown)
        #expect(troubled.state != .limited)
        #expect(troubled.state != .busy)
        #expect(!troubled.reasons.map(\.code).contains("control"))
        #expect(!troubled.reasons.map(\.code).contains("window_pct"))
    }

    @Test func halTokOnlySamplesDriveDegradation() {
        // hal probes have ttft nil on every sample, so the probe rules must
        // work purely on tok/s vs the learned median. History median 80 /
        // MAD 2 ⇒ a 71 tok/s tail is z = 9/2 = 4.5 (over zWarn, under
        // zCrawl); a 40 tok/s tail is z = 20.
        let moderate = halHistory() + [halSample(at: 37 * 60, tokPerSec: 71),
                                       halSample(at: 38 * 60, tokPerSec: 71),
                                       halSample(at: 39 * 60, tokPerSec: 71)]
        let degraded = verdict(.hal, probes: moderate)
        #expect(degraded.state == .degraded)
        #expect(degraded.reasons.first?.code == "toks_z")
        #expect(degraded.reasons.first?.detail.contains("tok/s") == true)
        #expect(degraded.reasons.first?.detail.contains("qwen3.8-flash") == true)

        let slow = halHistory() + [halSample(at: 37 * 60, tokPerSec: 40),
                                   halSample(at: 38 * 60, tokPerSec: 40),
                                   halSample(at: 39 * 60, tokPerSec: 40)]
        let crawling = verdict(.hal, probes: slow)
        #expect(crawling.state == .crawling)
        #expect(crawling.reasons.first?.code == "toks_z")
    }

    @Test func halCountsInMenuBarLadder() {
        // hal has no percent windows, but its verdict still rides the colour
        // ladder: degraded hal tints the menu bar amber while Claude and
        // Codex are healthy (and the title keeps the percent leader).
        let snapshots: [ProviderID: ProviderSnapshot] = [
            .claude: snapshot(.claude, percents: [40]),
            .codex: snapshot(.codex, percents: [20]),
            .hal: snapshot(.hal),
        ]
        func ok(_ id: ProviderID) -> Verdict {
            Verdict(provider: id, state: .ok, reasons: [], computedAt: now)
        }
        let halDegraded = Verdict(
            provider: .hal, state: .degraded,
            reasons: [VerdictReason(
                code: "toks_z",
                detail: "z=4.5 · 71.0 tok/s vs 80.0 median · qwen3.8-flash")],
            computedAt: now)
        let result = StatusItemModel.title(
            for: snapshots, pollInterval: 300, now: now,
            verdicts: [.claude: ok(.claude), .codex: ok(.codex), .hal: halDegraded])
        #expect(result.title == "✳ 40%")
        #expect(result.color == .amber)
    }

    @Test func divergenceIgnoresHal() throws {
        // hal is the homelab box: there is no hosted status page that could
        // agree or disagree with it, so its verdicts stay out of the banner.
        let halDegraded = Verdict(
            provider: .hal, state: .degraded,
            reasons: [VerdictReason(
                code: "toks_z",
                detail: "z=4.5 · 71.0 tok/s vs 80.0 median · qwen3.8-flash")],
            computedAt: now)
        let halProbe = halSample(at: 39 * 60, tokPerSec: 71)
        func ok(_ id: ProviderID) -> Verdict {
            Verdict(provider: id, state: .ok, reasons: [], computedAt: now)
        }
        // hal degraded + Claude/Codex OK + no status signal ⇒ nothing to say.
        #expect(VerdictEngine.divergence(
            verdicts: [.claude: ok(.claude), .codex: ok(.codex), .hal: halDegraded],
            statuses: [:], latestProbes: [halProbe]) == nil)

        // And hal trouble must not silence Claude's genuine banner.
        let slow = fast(24) + [sample(at: 37 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 38 * 60, ttft: 21, tokPerSec: 9),
                               sample(at: 39 * 60, ttft: 21, tokPerSec: 9)]
        let crawl = verdict(probes: slow, controls: controls([0.4, 0.4, 0.4]))
        #expect(crawl.state == .crawling)
        let banner = try #require(VerdictEngine.divergence(
            verdicts: [.claude: crawl, .hal: halDegraded],
            statuses: [.claude: .operational], latestProbes: slow + [halProbe]))
        #expect(banner.contains("Claude Crawling"))
        #expect(!banner.contains("Hal"))
    }

    // MARK: - §13 acceptance scenario

    @Test func acceptanceCrawlingCodexWithBanner() throws {
        let fillers = (0..<24).map { index in
            sample(at: 12 * 60 + Double(index) * 60, ttft: 1.9, tokPerSec: 78,
                   model: "gpt-6-astra", provider: .codex)
        }
        let slowTail = [
            sample(at: 37 * 60, ttft: 21.4, tokPerSec: 9, model: "gpt-6-astra", provider: .codex),
            sample(at: 38 * 60, ttft: 21.4, tokPerSec: 9, model: "gpt-6-astra", provider: .codex),
            sample(at: 39 * 60, ttft: 21.4, tokPerSec: 9, model: "gpt-6-astra", provider: .codex),
        ]
        let codexControls = controls([0.4, 0.4, 0.4], id: .codex)
        let result = verdict(
            .codex, probes: fillers + slowTail, controls: codexControls, percents: [12])
        #expect(result.state == .crawling)

        let banner = VerdictEngine.divergence(
            verdicts: [.codex: result], statuses: [.codex: .operational],
            latestProbes: fillers + slowTail)
        let text = try #require(banner)
        #expect(text.contains("Status pages:"))
        #expect(text.contains("Codex Crawling"))
        #expect(text.contains("21.4 s"))
        #expect(text.contains("9 tok/s"))
        #expect(text.contains("gpt-6-astra"))
    }
}
