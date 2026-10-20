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

    // MARK: - Sparklines

    @Test func sparklinesNormalizeBySegmentMedian() {
        // 22 identical samples ⇒ learned median equals the value ⇒ flat 1.0.
        let recent = (0..<22).map { sample(offset: -Double($0) * 120) }
        let model = section(recent: recent)
        #expect(model.sparkTTFT.count == 22)
        #expect(model.sparkTTFT.allSatisfy { abs($0 - 1.0) < 0.001 })
        #expect(model.sparkTokPerSec.allSatisfy { abs($0 - 1.0) < 0.001 })
    }

    @Test func sparklinesExcludeNonOkAndStaleAndDecimate() {
        var recent: [ProbeSample] = (0..<60).map { sample(offset: -Double($0) * 600) }  // 10 h span
        recent += [sample(offset: -60, ttft: nil, tokPerSec: nil, outcome: .timeout),
                   sample(offset: -30 * 3600)]  // outside 24 h
        let usable = recent.filter {
            $0.outcome == .ok && $0.ttft != nil && now.timeIntervalSince($0.timestamp) <= 24 * 3600
        }.count
        #expect(usable == 60)
        let model = section(recent: recent)
        #expect(model.sparkTTFT.count <= 48)
        #expect(model.sparkTTFT.count >= 24)
    }

    @Test func sparklineSamplesMissingMetricDroppedPerMetric() {
        let recent = [
            sample(offset: -60, ttft: 2.0, tokPerSec: nil),
            sample(offset: -120, ttft: nil, tokPerSec: 80),
        ]
        let model = section(recent: recent)
        #expect(model.sparkTTFT.count == 1)
        #expect(model.sparkTokPerSec.count == 1)
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
