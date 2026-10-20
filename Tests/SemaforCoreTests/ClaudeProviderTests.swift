import Foundation
import Testing

@testable import SemaforCore

private struct FakeClaudeCredentials: ClaudeCredentialReading {
    enum Mode: Sendable {
        case token(String)
        case missing
        case expired
    }

    let mode: Mode

    func accessToken() throws -> String {
        switch mode {
        case .token(let token): return token
        case .missing: throw ProviderError.auth(.missingCredentials)
        case .expired: throw ProviderError.auth(.expiredCredentials)
        }
    }
}

private final class CallCounter: @unchecked Sendable {
    var count = 0
}

@Suite("ClaudeProvider")
struct ClaudeProviderTests {
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private func makeProvider(
        credentials: FakeClaudeCredentials,
        client: StubHTTPClient
    ) -> ClaudeProvider {
        ClaudeProvider(
            http: client,
            credentials: credentials,
            settings: AppSettings(defaults: UserDefaults(suiteName: "ClaudeProviderTests.\(UUID().uuidString)")!))
    }

    private func okStub(_ data: Data, counter: CallCounter? = nil) -> StubHTTPClient {
        StubHTTPClient { _ in
            counter?.count += 1
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test func fetchLimitsDecodesBothWindows() async throws {
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .token("test-token")),
            client: okStub(try fixtureData("claude-usage.json")))

        let windows = try await provider.fetchLimits()

        let fiveHour = try #require(windows.first { $0.name == .fiveHour })
        #expect(fiveHour.usedPercent == 42.0)
        #expect(fiveHour.resetsAt == date("2026-10-20T09:30:00Z"))
        #expect(fiveHour.windowSeconds == 18_000)

        let sevenDay = try #require(windows.first { $0.name == .sevenDay })
        #expect(sevenDay.usedPercent == 68.5)
        #expect(sevenDay.resetsAt == date("2026-10-23T09:30:00Z"))
        #expect(sevenDay.windowSeconds == 604_800)
        #expect(windows.count == 2)
    }

    @Test func expiredTokenStatusMapsToAuth() async {
        let client = StubHTTPClient { _ in
            (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .token("stale")), client: client)
        await #expect(throws: ProviderError.auth(.expiredCredentials)) {
            _ = try await provider.fetchLimits()
        }
    }

    @Test func missingCredentialsShortCircuitBeforeHTTP() async {
        let counter = CallCounter()
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .missing),
            client: okStub(Data("{}".utf8), counter: counter))
        await #expect(throws: ProviderError.auth(.missingCredentials)) {
            _ = try await provider.fetchLimits()
        }
        #expect(counter.count == 0)
    }

    @Test func malformedPayloadKeepsSurvivingWindowsWithNils() async throws {
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .token("test-token")),
            client: okStub(try fixtureData("claude-usage-malformed.json")))

        let windows = try await provider.fetchLimits()

        #expect(windows.count == 1)
        let sevenDay = try #require(windows.first)
        #expect(sevenDay.name == .sevenDay)
        #expect(sevenDay.usedPercent == nil)
        #expect(sevenDay.resetsAt == nil)
    }

    @Test func requestCarriesAuthAndBetaHeaders() async throws {
        final class Box: @unchecked Sendable { var last: URLRequest? }
        let box = Box()
        let client = StubHTTPClient { request in
            box.last = request
            return (Data(#"{"five_hour":{"utilization":1,"resets_at":"2026-10-20T09:30:00Z"}}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .token("test-token")), client: client)
        _ = try await provider.fetchLimits()

        #expect(box.last?.url == ClaudeProvider.usageURL)
        #expect(box.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(box.last?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func fractionScalePayloadIsScaledToPercent() async throws {
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .token("test-token")),
            client: okStub(Data(#"{"five_hour":{"utilization":0.42,"resets_at":"2026-10-20T09:30:00Z"}}"#.utf8)))
        let windows = try await provider.fetchLimits()
        #expect(try #require(windows.first).usedPercent == 42.0)
    }

    @Test func mixedPayloadAboveOneIsPercentAsIs() async throws {
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .token("test-token")),
            client: okStub(Data(
                #"{"five_hour":{"utilization":0.42},"seven_day":{"utilization":68.5}}"#.utf8)))
        let windows = try await provider.fetchLimits()
        #expect(windows.first { $0.name == .fiveHour }?.usedPercent == 0.42)
        #expect(windows.first { $0.name == .sevenDay }?.usedPercent == 68.5)
    }

    @Test func stringUtilizationDecodesLeniently() async throws {
        // Drift pin (Review Focus class 1): Anthropic shipping
        // "utilization": "42.5" must nil-degrade values, not blank both
        // windows via a whole-document .decoding failure.
        let provider = makeProvider(
            credentials: FakeClaudeCredentials(mode: .token("test-token")),
            client: okStub(Data(
                #"{"five_hour":{"utilization":"42.5","resets_at":"2026-10-20T09:30:00Z"}}"#.utf8)))
        let windows = try await provider.fetchLimits()
        let fiveHour = try #require(windows.first)
        #expect(fiveHour.usedPercent == 42.5)
    }
}
