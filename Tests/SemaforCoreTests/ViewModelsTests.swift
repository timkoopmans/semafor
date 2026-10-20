import Foundation
import Testing

@testable import SemaforCore

@Suite("ProviderSectionModel")
struct ProviderSectionModelTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let pollInterval: TimeInterval = 300

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "ViewModelsTests.\(UUID().uuidString)")!)
    }

    private func snapshot(
        _ provider: ProviderID = .claude,
        windows: [UsageWindow],
        error: ProviderError? = nil,
        fetchedAt: Date? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider, windows: windows,
            fetchedAt: fetchedAt ?? now, lastError: error)
    }

    @Test func normalRowsRenderPercentAndCountdown() {
        let windows = [
            UsageWindow(name: .fiveHour, usedPercent: 62, windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60), fetchedAt: now),
            UsageWindow(name: .sevenDay, usedPercent: 30, windowSeconds: 604_800,
                        resetsAt: now.addingTimeInterval(4 * 24 * 3600 + 2 * 3600), fetchedAt: now),
        ]
        let model = ProviderSectionModel(
            snapshot: snapshot(windows: windows), projections: [:], now: now,
            settings: settings(), pollInterval: pollInterval)

        #expect(model.providerID == .claude)
        #expect(model.displayName == "Claude")
        #expect(model.glyph == "✳")
        #expect(model.rows.count == 2)
        #expect(model.rows[0].label == "5-hour")
        #expect(model.rows[0].percentText == "62%")
        #expect(model.rows[0].barPercent == 62)
        #expect(model.rows[0].resetsText == "resets in 3h 12m")
        // 62 % used over 36 % elapsed (11 520 s into an 18 000 s window) → +26 pts.
        #expect(model.rows[0].paceText == "ahead of pace (+26 pts)")
        #expect(model.rows[0].dimmed == false)
        #expect(model.rows[1].label == "7-day")
        #expect(model.rows[1].resetsText == "resets in 4d 2h")
        #expect(model.rows[1].paceText == nil)  // 30 % used over 75 % elapsed → within pace
        #expect(model.isStale == false)
        #expect(model.statusLine == "")
        #expect(model.headline == nil)
    }

    @Test func nilPercentAndResetsGetDashes() {
        let windows = [
            UsageWindow(name: .primary, usedPercent: nil, windowSeconds: nil, resetsAt: nil, fetchedAt: now),
        ]
        let model = ProviderSectionModel(
            snapshot: snapshot(.codex, windows: windows), projections: [:], now: now,
            settings: settings(), pollInterval: pollInterval)
        #expect(model.rows[0].label == "Primary")
        #expect(model.rows[0].percentText == "–")
        #expect(model.rows[0].barPercent == nil)
        #expect(model.rows[0].resetsText == "—")
    }

    @Test func pastResetRendersResetting() {
        let windows = [
            UsageWindow(name: .fiveHour, usedPercent: 10, windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(-60), fetchedAt: now),
        ]
        let model = ProviderSectionModel(
            snapshot: snapshot(windows: windows), projections: [:], now: now,
            settings: settings(), pollInterval: pollInterval)
        #expect(model.rows[0].resetsText == "resetting…")
    }

    @Test func zeroLeadingUnitsAreDropped() {
        let windows = [
            UsageWindow(name: .fiveHour, usedPercent: 10, windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(12 * 60), fetchedAt: now),
        ]
        let model = ProviderSectionModel(
            snapshot: snapshot(windows: windows), projections: [:], now: now,
            settings: settings(), pollInterval: pollInterval)
        #expect(model.rows[0].resetsText == "resets in 12m")
    }

    @Test func staleSnapshotDimsRows() {
        let windows = [
            UsageWindow(name: .fiveHour, usedPercent: 10, windowSeconds: 18_000, resetsAt: nil, fetchedAt: now),
        ]
        let model = ProviderSectionModel(
            snapshot: snapshot(windows: windows, fetchedAt: now.addingTimeInterval(-3 * pollInterval - 1)),
            projections: [:], now: now, settings: settings(), pollInterval: pollInterval)
        #expect(model.isStale == true)
        #expect(model.rows[0].dimmed == true)
    }

    @Test func errorStatusLinesPerProvider() {
        func line(_ provider: ProviderID, _ error: ProviderError) -> String {
            ProviderSectionModel(
                snapshot: snapshot(provider, windows: [], error: error),
                projections: [:], now: now, settings: settings(), pollInterval: pollInterval)
                .statusLine
        }
        #expect(line(.claude, .auth(.missingCredentials)) == "Not signed in — run `claude` once")
        #expect(line(.codex, .auth(.missingCredentials)) == "Not signed in — run `codex` once")
        #expect(line(.claude, .auth(.expiredCredentials)) == "Token expired — run `claude` once")
        #expect(line(.codex, .auth(.expiredCredentials)) == "Token expired — run `codex` once")
        #expect(line(.claude, .network) == "Network unreachable")
        #expect(line(.claude, .http(status: 503)) == "Provider API error (503)")
        #expect(line(.claude, .decoding("junk")) == "Unexpected provider response")
        #expect(line(.claude, .unimplemented) == "")
    }

    @Test func headlinePrefersLongestWindow() {
        func projection(_ text: String) -> BurnRateEstimator.Projection {
            BurnRateEstimator.Projection(
                slopePercentPerHour: 5, eta: nil, band: nil, headline: text)
        }
        let windows = [
            UsageWindow(name: .secondary, usedPercent: 10, windowSeconds: 18_000, resetsAt: nil, fetchedAt: now),
            UsageWindow(name: .sevenDay, usedPercent: 20, windowSeconds: 604_800, resetsAt: nil, fetchedAt: now),
        ]
        let model = ProviderSectionModel(
            snapshot: snapshot(.codex, windows: windows),
            projections: [
                .sevenDay: projection("seven day headline"),
                .secondary: projection("secondary headline"),
            ],
            now: now, settings: settings(), pollInterval: pollInterval)
        #expect(model.headline == "seven day headline")

        let secondaryOnly = ProviderSectionModel(
            snapshot: snapshot(.codex, windows: [windows[0]]),
            projections: [.secondary: projection("secondary headline")],
            now: now, settings: settings(), pollInterval: pollInterval)
        #expect(secondaryOnly.headline == "secondary headline")
    }

    @Test func paceTextWhenAheadOfSchedule() {
        let ahead = UsageWindow(
            name: .sevenDay, usedPercent: 51, windowSeconds: 604_800,
            resetsAt: now.addingTimeInterval(0.8 * 604_800), fetchedAt: now)  // elapsed 20 %
        let within = UsageWindow(
            name: .fiveHour, usedPercent: 25, windowSeconds: 18_000,
            resetsAt: now.addingTimeInterval(0.8 * 18_000), fetchedAt: now)  // elapsed 20 %
        let model = ProviderSectionModel(
            snapshot: snapshot(windows: [ahead, within]), projections: [:], now: now,
            settings: settings(), pollInterval: pollInterval)
        #expect(model.rows[0].paceText == "ahead of pace (+31 pts)")
        #expect(model.rows[1].paceText == nil)
    }
}

@Suite("StatusItemModel")
struct StatusItemModelTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let pollInterval: TimeInterval = 300

    private func snapshot(_ provider: ProviderID, _ percent: Double?, error: ProviderError? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider,
            windows: percent.map {
                [UsageWindow(name: .fiveHour, usedPercent: $0, windowSeconds: 18_000, resetsAt: nil, fetchedAt: now)]
            } ?? [],
            fetchedAt: now, lastError: error)
    }

    @Test func worstProviderWinsWithGlyph() {
        let result = StatusItemModel.title(
            for: [.claude: snapshot(.claude, 40), .codex: snapshot(.codex, 62)],
            pollInterval: pollInterval, now: now)
        #expect(result.title == "⬡ 62%")
        #expect(result.color == .green)
    }

    @Test func tiesGoToCodexFirst() {
        let result = StatusItemModel.title(
            for: [.claude: snapshot(.claude, 62), .codex: snapshot(.codex, 62)],
            pollInterval: pollInterval, now: now)
        #expect(result.title == "⬡ 62%")
    }

    @Test func emptyStatesRenderClaudeGlyphWithDash() {
        let result = StatusItemModel.title(for: [:], pollInterval: pollInterval, now: now)
        #expect(result.title == "✳ –")
        #expect(result.color == .grey)

        let nilPercent = StatusItemModel.title(
            for: [.claude: snapshot(.claude, nil)], pollInterval: pollInterval, now: now)
        #expect(nilPercent.title == "✳ –")
    }

    @Test func colorThresholdBoundaries() {
        func color(_ percent: Double) -> StatusItemModel.StatusColor {
            StatusItemModel.title(for: [.claude: snapshot(.claude, percent)], pollInterval: pollInterval, now: now).color
        }
        #expect(color(79.9) == .green)
        #expect(color(80) == .amber)
        #expect(color(97.9) == .amber)
        #expect(color(98) == .red)
    }

    @Test func authErrorsGreyButHighUsageRedsAcrossProviders() {
        let greyed = StatusItemModel.title(
            for: [.claude: snapshot(.claude, 40), .codex: snapshot(.codex, nil, error: .auth(.missingCredentials))],
            pollInterval: pollInterval, now: now)
        #expect(greyed.color == .grey)

        // Plan lists red first in the ladder: a near-exhausted window outranks
        // another provider's auth problem.
        let red = StatusItemModel.title(
            for: [.claude: snapshot(.claude, 99), .codex: snapshot(.codex, nil, error: .auth(.missingCredentials))],
            pollInterval: pollInterval, now: now)
        #expect(red.color == .red)
    }

    @Test func coldStartNonAuthFailureGreysNotGreen() {
        // Review fix I-2: nothing measured + repeated network failure must
        // not read "all fine" green (spec §8.2: network failure counts as
        // UNKNOWN, surfaced as grey pre-M3).
        let snapshots: [ProviderID: ProviderSnapshot] = [
            .claude: ProviderSnapshot(providerID: .claude, windows: [], fetchedAt: now, lastError: .network),
            .codex: ProviderSnapshot(providerID: .codex, windows: [], fetchedAt: now, lastError: .network),
        ]
        let result = StatusItemModel.title(for: snapshots, pollInterval: pollInterval, now: now)
        #expect(result.title == "✳ –")
        #expect(result.color == .grey)
    }
}
