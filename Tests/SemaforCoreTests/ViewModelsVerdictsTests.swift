import Foundation
import Testing
@testable import SemaforCore

/// Verdict chip, sparklines, measured caption, and the menu-bar colour
/// ladder extended with verdicts (spec §9).
struct ViewModelsVerdictsTests {
    private let now = Date(timeIntervalSince1970: 1_760_860_800)  // Mon 10:00 UTC

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "ViewModelsVerdictsTests.\(UUID().uuidString)")!)
    }

    private func snapshot(
        _ id: ProviderID = .claude, percent: Double? = 10, error: ProviderError? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            windows: [UsageWindow(name: .primary, usedPercent: percent, windowSeconds: 18_000, resetsAt: nil, fetchedAt: now)],
            fetchedAt: now, lastError: error)
    }

    private func sample(
        offset: TimeInterval, ttft: Double? = 2.0, tokPerSec: Double? = 80,
        model: String = "claude-opus-5-5", provider: ProviderID = .claude,
        outcome: ProbeOutcome = .ok
    ) -> ProbeSample {
        ProbeSample(
            provider: provider, model: model, sessionKey: "f#\(offset)",
            ttft: ttft, duration: 3, tokensPerSecond: tokPerSec,
            outcome: outcome, timestamp: now.addingTimeInterval(offset))
    }

    private func section(
        snap: ProviderSnapshot? = nil, verdict: Verdict? = nil,
        latestProbe: ProbeSample? = nil, recent: [ProbeSample] = [],
        divergenceText: String? = nil, measuredToday: Int = 0
    ) -> ProviderSectionModel {
        ProviderSectionModel(
            snapshot: snap ?? snapshot(), projections: [:], now: now,
            settings: settings(), pollInterval: 300,
            verdict: verdict, latestProbe: latestProbe, recentSamples: recent,
            divergenceText: divergenceText, measuredToday: measuredToday)
    }

    private func verdict(_ state: ProviderState, provider: ProviderID = .claude) -> Verdict {
        Verdict(provider: provider, state: state,
                reasons: [VerdictReason(code: "ttft_z", detail: "z=8.0 · TTFT 21.4s vs 2.1s median · claude-opus-5-5")],
                computedAt: now)
    }

    // MARK: - Chip

    @Test func chipCopyShortensModelAndCarriesLatestMetrics() {
        let probe = sample(offset: -60, ttft: 21.4, tokPerSec: 9)
        let model = section(verdict: verdict(.crawling), latestProbe: probe)
        #expect(model.verdictChip == "Crawling · Opus 5.5 · TTFT 21.4 s · 9 tok/s")

        let degraded = section(verdict: verdict(.degraded), latestProbe: sample(offset: -60, ttft: 9.0, tokPerSec: 40))
        #expect(degraded.verdictChip == "Degraded · Opus 5.5 · TTFT 9.0 s · 40 tok/s")

        let noProbe = section(verdict: verdict(.limited))
        #expect(noProbe.verdictChip == "Limited")
    }

    @Test func chipHiddenWhenQuiet() {
        #expect(section(verdict: nil, latestProbe: sample(offset: -60)).verdictChip == nil)
        #expect(section(verdict: verdict(.ok), latestProbe: sample(offset: -60)).verdictChip == nil)
    }

    @Test func chipColors() {
        #expect(section(verdict: verdict(.ok)).chipColor == .green)
        #expect(section(verdict: verdict(.busy)).chipColor == .amber)
        #expect(section(verdict: verdict(.degraded)).chipColor == .amber)
        #expect(section(verdict: verdict(.crawling)).chipColor == .red)
        #expect(section(verdict: verdict(.limited)).chipColor == .red)
        #expect(section(verdict: verdict(.unknown)).chipColor == .grey)
    }

    // MARK: - Metric tiles (value + fixed-domain sparkline, review feedback)

    /// 22 uniform samples at tok/s 80 / ttft 2.0 ⇒ learned segment median;
    /// `latestTok` optionally overrides the newest sample's throughput.
    private func learnedSeries(latestTok: Double? = 80, latestTtft: Double? = 2.0) -> [ProbeSample] {
        var recent = (1..<22).map { sample(offset: -Double($0) * 120) }  // 21 uniform @80/2.0
        recent.append(sample(offset: -60, ttft: latestTtft, tokPerSec: latestTok))
        return recent
    }

    @Test func tilesShowLatestValueAndLearnedUsual() {
        let model = section(recent: learnedSeries(latestTok: 80))
        #expect(model.tileTokPerSec?.valueText == "80 tok/s")
        #expect(model.tileTokPerSec?.usualText == "usual 80")
        #expect(model.tileTTFT?.valueText == "2.0 s")
        #expect(model.tileTTFT?.usualText == "usual 2.0 s")
    }

    @Test func tileColorLadderFollowsDirectionalZ() {
        // MAD collapses to 0 ⇒ MAD floor 2 for tok/s: z = (80 − v)/2.
        let green = section(recent: learnedSeries(latestTok: 80))
        #expect(green.tileTokPerSec?.color == .green)

        let amber = section(recent: learnedSeries(latestTok: 73))  // z 3.5
        #expect(amber.tileTokPerSec?.color == .amber)
        #expect(amber.tileTokPerSec?.valueText == "73 tok/s")

        let red = section(recent: learnedSeries(latestTok: 9))  // z 35.5
        #expect(red.tileTokPerSec?.color == .red)

        // ttft side: floor 0.25 ⇒ 21 s vs median 2 ⇒ z 76 red; fast ttft stays
        // green (direction guard: low tok/s and HIGH ttft are the bad sides).
        let ttftRed = section(recent: learnedSeries(latestTtft: 21))
        #expect(ttftRed.tileTTFT?.color == .red)
        let ttftFast = section(recent: learnedSeries(latestTtft: 0.1))
        #expect(ttftFast.tileTTFT?.color == .green)
        let tokFast = section(recent: learnedSeries(latestTok: 400))
        #expect(tokFast.tileTokPerSec?.color == .green)
    }

    @Test func tilesUseAbsoluteDefaultsWhenUnlearned() {
        let model = section(recent: [sample(offset: -60, ttft: 5, tokPerSec: 50)])
        #expect(model.tileTokPerSec?.usualText == "usual 20")  // baselineDefaultTokPerSec
        #expect(model.tileTokPerSec?.valueText == "50 tok/s")
        #expect(model.tileTokPerSec?.color == .green)  // 50 > 20 ⇒ fast side
        #expect(model.tileTTFT?.usualText == "usual 8.0 s")  // baselineDefaultTTFT
        #expect(model.tileTTFT?.color == .green)  // 5 < 8 ⇒ fast side
    }

    @Test func tilesNilWithoutUsableSamples() {
        let empty = section(recent: [])
        #expect(empty.tileTTFT == nil)
        #expect(empty.tileTokPerSec == nil)

        let onlyTimeouts = section(recent: [
            sample(offset: -60, ttft: nil, tokPerSec: nil, outcome: .timeout),
        ])
        #expect(onlyTimeouts.tileTTFT == nil)
        #expect(onlyTimeouts.tileTokPerSec == nil)
    }

    @Test func tilesExcludeNonOkStaleAndDecimateSeries() {
        var recent: [ProbeSample] = (0..<60).map { sample(offset: -Double($0) * 600) }  // 10 h span
        recent += [sample(offset: -61, ttft: nil, tokPerSec: nil, outcome: .timeout),
                   sample(offset: -30 * 3600)]  // outside 24 h
        let model = section(recent: recent)
        #expect(model.tileTTFT?.series.count ?? 0 <= 48)
        #expect(model.tileTTFT?.series.count ?? 0 >= 24)
    }

    @Test func seriesIsFixedDomainNotAutoScaled() {
        // Review complaint: auto-scaled squiggles look identical whatever the
        // data; on a fixed 0…2×-median domain values clamp at 2 and a
        // at-median series sits exactly at 1.
        let flat = section(recent: learnedSeries(latestTok: 80))
        #expect(flat.tileTokPerSec?.series.allSatisfy { abs($0 - 1.0) < 0.001 } == true)

        let spike = section(recent: learnedSeries(latestTok: 400))  // 400/80 = 5 ⇒ clamp 2
        #expect(spike.tileTokPerSec?.series.max() == 2.0)
        let dip = section(recent: learnedSeries(latestTok: 20))  // 20/80 = 0.25
        #expect(dip.tileTokPerSec?.series.min() == 0.25)
    }

    // MARK: - Tokens-per-day bar strip

    private func daySamples(_ dayOffset: Int, _ tokenCounts: [Int?], provider: ProviderID = .claude) -> [ProbeSample] {
        let cal = Calendar.current
        guard let dayStart = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else {
            fatalError("no day start")
        }
        let ts = dayStart.addingTimeInterval(3 * 3600)  // mid-day, calendar-safe
        return tokenCounts.enumerated().map { index, tokens in
            ProbeSample(
                provider: provider, model: "claude-opus-5-5",
                sessionKey: "day#\(dayOffset)-\(index)",
                ttft: 2.0, duration: 3, tokensPerSecond: 80,
                tokens: tokens, outcome: .ok, timestamp: ts)
        }
    }

    @Test func tokenBarsSumPerLocalDayAndCaption() throws {
        var recent = daySamples(0, [500, 7400]) + daySamples(-1, [12000]) + daySamples(-3, [38000])
        recent += [sample(offset: -60, ttft: nil, tokPerSec: nil, outcome: .timeout)]  // never counted
        let model = section(recent: recent)
        let bars = try #require(model.tokenBars)
        #expect(bars.count == 7)
        #expect(bars[6].isToday)
        #expect(bars[6].tokens == 7900)
        #expect(bars[5].tokens == 12000)
        #expect(bars[3].tokens == 38000)
        #expect(bars[0].tokens == 0)  // empty days still draw a slot
        #expect(bars[3].height == 1.0)  // peak day normalizes to full height
        #expect(abs(bars[6].height - 7900.0 / 38000.0) < 0.0001)
        #expect(model.tokenCaption == "7.9k tok today · peak 38k this week")
    }

    @Test func tokenBarsNilWithoutCounts() {
        #expect(section(recent: []).tokenBars == nil)
        #expect(section(recent: [sample(offset: -60)]).tokenCaption == nil)  // helper stores nil counts
        let mixed = section(recent: daySamples(0, [nil, 1200]))
        #expect(mixed.tokenBars?.last?.tokens == 1200)  // nil counts skipped
    }

    @Test func tokenCaptionFormats() {
        let small = section(recent: daySamples(0, [850]))
        #expect(small.tokenCaption == "850 tok today · peak 850 this week")
        let big = section(recent: daySamples(0, [1_234_567]))
        #expect(big.tokenCaption == "1.2M tok today · peak 1.2M this week")
    }

    // MARK: - Measured caption and banner

    @Test func measuredText() {
        #expect(section(measuredToday: 34).measuredText == "measured 34 calls today")
        #expect(section(measuredToday: 0).measuredText == nil)
    }

    @Test func divergenceTextPassesThrough() {
        #expect(section(divergenceText: "Status pages: ✅").divergenceText == "Status pages: ✅")
    }

    // MARK: - Menu-bar colour ladder

    @Test func verdictsExtendTheStatusLadder() {
        func color(_ verdicts: [ProviderID: Verdict], _ snaps: [ProviderID: ProviderSnapshot]) -> StatusItemModel.StatusColor {
            StatusItemModel.title(for: snaps, pollInterval: 300, now: now, verdicts: verdicts).color
        }
        // Red from verdict even at low percent.
        #expect(color([.codex: verdict(.crawling, provider: .codex)],
                      [.codex: snapshot(.codex, percent: 10)]) == .red)
        // Amber from degraded.
        #expect(color([.claude: verdict(.degraded)],
                      [.claude: snapshot(percent: 10)]) == .amber)
        // Grey only when no red/amber above it.
        #expect(color([.claude: verdict(.unknown), .codex: verdict(.busy, provider: .codex)],
                      [.claude: snapshot(), .codex: snapshot(.codex)]) == .amber)  // busy beats unknown
        #expect(color([.claude: verdict(.unknown)], [.claude: snapshot()]) == .grey)
        // Percent ladder still applies untouched.
        #expect(color([:], [.claude: snapshot(percent: 98)]) == .red)
        #expect(color([:], [.claude: snapshot(percent: 80)]) == .amber)
        // Green only with nothing troubling.
        #expect(color([:], [.claude: snapshot(percent: 10)]) == .green)
        // Verdict-only world (no snapshots yet): ladder still fires.
        #expect(color([.claude: verdict(.limited)], [:]) == .red)
        #expect(color([:], [:]) == .grey)
    }

    @Test func existingTitleCopyUnchanged() {
        let result = StatusItemModel.title(
            for: [.codex: snapshot(.codex, percent: 42)], pollInterval: 300, now: now)
        #expect(result.title == "⬡ 42%")
    }
}
