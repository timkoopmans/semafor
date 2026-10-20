import Foundation
import Testing

@testable import SemaforCore

private struct FakeCodexAuth: CodexAuthReading {
    enum Mode: Sendable {
        case tokens(CodexTokens)
        case missing
    }

    let mode: Mode

    func tokens() throws -> CodexTokens {
        switch mode {
        case .tokens(let tokens): return tokens
        case .missing: throw ProviderError.auth(.missingCredentials)
        }
    }
}

private final class CallCounter: @unchecked Sendable {
    var count = 0
    var last: URLRequest?
}

@Suite("CodexFileReader")
struct CodexFileReaderTests {
    private func tempHome(withFixture fixture: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexFileReaderTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let fixture {
            try fixtureData(fixture).write(to: dir.appendingPathComponent("auth.json"))
        }
        return dir
    }

    @Test func readerDecodesTokensFromAuthFile() throws {
        let home = try tempHome(withFixture: "codex-auth.json")
        let tokens = try CodexFileReader(home: home).tokens()
        #expect(tokens.accessToken == "test-access-token")
        #expect(tokens.refreshToken == "test-refresh-token")
        #expect(tokens.accountId == "acct-123")
    }

    @Test func readerThrowsWhenAccessTokenMissing() throws {
        let home = try tempHome(withFixture: "codex-auth-missing-keys.json")
        #expect(throws: ProviderError.auth(.missingCredentials)) {
            _ = try CodexFileReader(home: home).tokens()
        }
    }

    @Test func readerThrowsWhenFileMissing() throws {
        let home = try tempHome(withFixture: nil)
        #expect(throws: ProviderError.auth(.missingCredentials)) {
            _ = try CodexFileReader(home: home).tokens()
        }
    }
}

@Suite("CodexProvider")
struct CodexProviderTests {
    private let url = URL(string: "https://chatgpt.com/backend-api/codex/usage")!

    private func makeProvider(auth: FakeCodexAuth, client: StubHTTPClient) -> CodexProvider {
        CodexProvider(
            http: client,
            auth: auth,
            settings: AppSettings(defaults: UserDefaults(suiteName: "CodexProviderTests.\(UUID().uuidString)")!))
    }

    private func okStub(_ data: Data, counter: CallCounter? = nil) -> StubHTTPClient {
        StubHTTPClient { request in
            counter?.count += 1
            counter?.last = request
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private var validTokens: CodexTokens {
        CodexTokens(accessToken: "test-access-token", refreshToken: nil, accountId: "acct-123")
    }

    @Test func fetchLimitsDecodesBothWindows() async throws {
        let counter = CallCounter()
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .tokens(validTokens)),
            client: okStub(try fixtureData("codex-usage.json"), counter: counter))

        let windows = try await provider.fetchLimits()

        let primary = try #require(windows.first { $0.name == .primary })
        #expect(primary.usedPercent == 57.0)
        #expect(primary.windowSeconds == 604_800)
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_792_884_737))

        let secondary = try #require(windows.first { $0.name == .secondary })
        #expect(secondary.usedPercent == 12.5)
        #expect(secondary.windowSeconds == 18_000)
        #expect(secondary.resetsAt == Date(timeIntervalSince1970: 1_765_000_000))
        #expect(windows.count == 2)

        #expect(counter.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(counter.last?.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-123")
    }

    @Test func expiredStatusMapsToAuth() async {
        let client = StubHTTPClient { _ in
            (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(auth: FakeCodexAuth(mode: .tokens(validTokens)), client: client)
        await #expect(throws: ProviderError.auth(.expiredCredentials)) {
            _ = try await provider.fetchLimits()
        }
    }

    @Test func missingAuthShortCircuitsBeforeHTTP() async {
        let counter = CallCounter()
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .missing),
            client: okStub(Data("{}".utf8), counter: counter))
        await #expect(throws: ProviderError.auth(.missingCredentials)) {
            _ = try await provider.fetchLimits()
        }
        #expect(counter.count == 0)
    }

    @Test func malformedKeepsSurvivingWindowsWithNils() async throws {
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .tokens(validTokens)),
            client: okStub(try fixtureData("codex-usage-malformed.json")))

        let windows = try await provider.fetchLimits()

        #expect(windows.count == 1)
        let secondary = try #require(windows.first)
        #expect(secondary.name == .secondary)
        #expect(secondary.usedPercent == nil)
        #expect(secondary.windowSeconds == nil)
        #expect(secondary.resetsAt == Date(timeIntervalSince1970: 1_765_000_000))
    }

    @Test func accountHeaderOmittedWhenNil() async throws {
        let counter = CallCounter()
        let tokens = CodexTokens(accessToken: "t", refreshToken: nil, accountId: nil)
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .tokens(tokens)),
            client: okStub(Data(#"{"rate_limits":{}}"#.utf8), counter: counter))
        _ = try await provider.fetchLimits()
        #expect(counter.last?.value(forHTTPHeaderField: "chatgpt-account-id") == nil)
    }

    @Test func fractionScaleScaledToPercent() async throws {
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .tokens(validTokens)),
            client: okStub(Data(
                #"{"rate_limits":{"primary_window":{"used_percent":0.42}}}"#.utf8)))
        let windows = try await provider.fetchLimits()
        #expect(try #require(windows.first).usedPercent == 42.0)
    }

    @Test func pluralRateLimitsAliasStillDecodes() async throws {
        // Endpoint drift pin (Review Focus): the live endpoint reports
        // `rate_limit`/`reset_at`; the originally planned plural/spelling
        // variants must keep working if OpenAI renames again.
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .tokens(validTokens)),
            client: okStub(Data(
                #"{"rate_limits":{"primary_window":{"used_percent":11,"limit_window_seconds":18000,"resets_at":"2026-10-20T09:30:00Z"}}}"#.utf8)))
        let windows = try await provider.fetchLimits()
        let primary = try #require(windows.first { $0.name == .primary })
        #expect(primary.usedPercent == 11.0)
        #expect(primary.windowSeconds == 18_000)
        #expect(primary.resetsAt != nil)
    }

    @Test func epochMillisecondsResetIsNormalized() async throws {
        // Drift pin: 13-digit millisecond epochs decode to sane dates,
        // not to year ~57,000 "resets in 20541423d".
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .tokens(validTokens)),
            client: okStub(Data(
                #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1765000000000}}}"#.utf8)))
        let windows = try await provider.fetchLimits()
        #expect(try #require(windows.first).resetsAt == Date(timeIntervalSince1970: 1_765_000_000))
    }

    @Test func malformedSingularFallsBackToPluralAlias() async throws {
        // `rate_limit` present but wrong shape must not abort the document;
        // the plural alias still gets its chance.
        let provider = makeProvider(
            auth: FakeCodexAuth(mode: .tokens(validTokens)),
            client: okStub(Data(
                #"{"rate_limit":17,"rate_limits":{"primary_window":{"used_percent":11,"limit_window_seconds":18000}}}"#.utf8)))
        let windows = try await provider.fetchLimits()
        let primary = try #require(windows.first { $0.name == .primary })
        #expect(primary.usedPercent == 11.0)
    }
}
