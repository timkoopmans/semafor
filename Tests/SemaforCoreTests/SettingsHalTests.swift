import Foundation
import Testing
@testable import SemaforCore

/// Identity and settings for the local Qwen provider (`hal`).
struct SettingsHalTests {
    private func freshSettings() -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "semafor-tests-hal-\(UUID().uuidString)")!
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test func defaultsMatchSpec() {
        let (settings, _) = freshSettings()
        #expect(settings.halEnabled)
        #expect(settings.halBaseURL == "http://hal:8000/v1")
        #expect(settings.halModelName == "Qwen3.8-Flash-Next")
        #expect(settings.halDbPath == "")
    }

    @Test func setReadRoundTrips() {
        let (settings, _) = freshSettings()
        settings.halEnabled = false
        settings.halBaseURL = "http://127.0.0.1:9000/v1"
        settings.halModelName = "Qwen-Test"
        settings.halDbPath = "/tmp/opencode.db"
        #expect(settings.halEnabled == false)
        #expect(settings.halBaseURL == "http://127.0.0.1:9000/v1")
        #expect(settings.halModelName == "Qwen-Test")
        #expect(settings.halDbPath == "/tmp/opencode.db")
    }

    @Test func providerIdentityIsQwen() {
        #expect(ProviderID.hal.displayName == "Qwen")
        #expect(ProviderID.hal.menuGlyph == "◈")
        #expect(ProviderID.allCases.last == .hal)
    }
}
