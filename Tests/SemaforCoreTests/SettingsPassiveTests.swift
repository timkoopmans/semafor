import Foundation
import Testing
@testable import SemaforCore

/// Defaults, persistence, and Thresholds mapping for the passive measurement
/// policy (spec §7–§8).
struct SettingsPassiveTests {
    private func freshSettings() -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "semafor-tests-\(UUID().uuidString)")!
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test func defaultsMatchSpec() {
        let (settings, _) = freshSettings()
        #expect(settings.scanIntervalSeconds == 60)
        #expect(settings.backfillDays == 7)
        #expect(settings.sampleRecencyMinutes == 30)
        #expect(settings.controlProbeEnabled)
        #expect(settings.controlIntervalMinutes == 5)
        #expect(settings.zWarn == 3)
        #expect(settings.zCrawl == 6)
        #expect(settings.consecutiveProbeN == 3)
        #expect(settings.busyPercent == 80)
        #expect(settings.limitedPercent == 98)
        #expect(settings.paceDeltaPoints == 15)
        #expect(settings.baselineMinSamples == 20)
        #expect(settings.baselineDefaultTTFT == 8)
        #expect(settings.baselineDefaultTokPerSec == 20)
    }

    @Test func setReadRoundTrips() {
        let (settings, _) = freshSettings()
        settings.scanIntervalSeconds = 30
        settings.controlProbeEnabled = false
        settings.zCrawl = 9
        #expect(settings.scanIntervalSeconds == 30)
        #expect(settings.controlProbeEnabled == false)
        #expect(settings.zCrawl == 9)
    }

    @Test func thresholdsReflectOverrides() {
        let (settings, _) = freshSettings()
        settings.zCrawl = 9
        settings.consecutiveProbeN = 5
        settings.sampleRecencyMinutes = 45
        let thresholds = settings.thresholds
        #expect(thresholds.zCrawl == 9)
        #expect(thresholds.zWarn == 3)
        #expect(thresholds.consecutiveN == 5)
        #expect(thresholds.sampleRecency == 45 * 60)
        #expect(thresholds.madFloorTTFT == 0.25)
        #expect(thresholds.madFloorTokPerSec == 2)
        #expect(thresholds.controlBadLatency == 5)
        #expect(thresholds.controlRecentCount == 3)
        #expect(thresholds.busyPercent == 80)
        #expect(thresholds.limitedPercent == 98)
        #expect(thresholds.paceDeltaPoints == 15)
        #expect(thresholds.baselineMinSamples == 20)
        #expect(thresholds.baselineDefaultTTFT == 8)
        #expect(thresholds.baselineDefaultTokPerSec == 20)
    }
}
