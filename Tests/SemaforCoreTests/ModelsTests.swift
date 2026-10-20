import Foundation
import Testing

@testable import SemaforCore

@Suite("UsageWindow")
struct UsageWindowTests {
    @Test func codableRoundTripWithNils() throws {
        let json =
            #"{"name":"fiveHour","usedPercent":null,"windowSeconds":null,"resetsAt":null,"fetchedAt":"2026-10-20T04:00:00Z"}"#
        let window = try #require(try? JSONDecoder().decode(UsageWindow.self, from: Data(json.utf8)))
        #expect(window.name == .fiveHour)
        #expect(window.usedPercent == nil)
        #expect(window.windowSeconds == nil)
        #expect(window.resetsAt == nil)

        let roundTripped = try JSONDecoder().decode(UsageWindow.self, from: try JSONEncoder().encode(window))
        #expect(roundTripped == window)
    }
}

@Suite("ProviderSnapshot")
struct ProviderSnapshotTests {
    @Test func memberwiseInitKeepsValues() {
        let window = UsageWindow(
            name: .primary, usedPercent: 62, windowSeconds: 18_000,
            resetsAt: nil, fetchedAt: Date(timeIntervalSince1970: 0))
        let snapshot = ProviderSnapshot(
            providerID: .codex, windows: [window],
            fetchedAt: Date(timeIntervalSince1970: 1),
            lastError: .auth(.expiredCredentials))

        #expect(snapshot.providerID == .codex)
        #expect(snapshot.windows == [window])
        #expect(snapshot.lastError == .auth(.expiredCredentials))
    }
}

@Suite("AppSettings")
struct AppSettingsTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "SemaforTests.\(UUID().uuidString)")!
    }

    @Test func defaultsFromEmptySuite() {
        let settings = AppSettings(defaults: freshSuite())
        #expect(settings.pollIntervalMinutes == 5)
        #expect(settings.quietHoursEnabled == true)
        #expect(settings.quietStart == "22:00")
        #expect(settings.quietEnd == "07:00")
        #expect(settings.claudeProbeModelID.isEmpty)
        #expect(settings.codexProbeModelID == "gpt-6-astra")
        #expect(settings.launchAtLogin == false)
    }

    @Test func writesPersistAcrossInstances() {
        let suiteName = "SemaforTests.\(UUID().uuidString)"
        let first = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        first.pollIntervalMinutes = 15
        first.launchAtLogin = true

        let second = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        #expect(second.pollIntervalMinutes == 15)
        #expect(second.launchAtLogin == true)
    }
}
