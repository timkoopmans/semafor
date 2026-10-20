import Foundation
import Testing
@testable import SemaforCore

/// Statuspage indicator mapping and the never-throwing status page fetch
/// behind both providers (spec §8.2 divergence input).
struct StatusPageTests {
    private func response(_ code: Int, for url: URL, body: Data = Data()) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    // MARK: - Mapping

    @Test func indicatorMapping() {
        #expect(StatuspageMapping.state(indicator: "none") == .operational)
        #expect(StatuspageMapping.state(indicator: "minor") == .degraded)
        #expect(StatuspageMapping.state(indicator: "major") == .majorDisruption)
        #expect(StatuspageMapping.state(indicator: "critical") == .majorDisruption)
        #expect(StatuspageMapping.state(indicator: "catastrophic") == .unknown)
        #expect(StatuspageMapping.state(indicator: nil) == .unknown)
    }

    @Test func liveFixturesDecodeAsOperational() throws {
        for name in ["statuspage-claude.json", "statuspage-openai.json"] {
            let dto = try JSONDecoder().decode(
                StatuspageDTO.self, from: fixtureData(name))
            #expect(StatuspageMapping.state(indicator: dto.status?.indicator) == .operational)
        }
    }

    @Test func permissiveDecoding() {
        // Missing everything ⇒ unknown, not a decode failure.
        let empty = try! JSONDecoder().decode(StatuspageDTO.self, from: Data("{}".utf8))
        #expect(StatuspageMapping.state(indicator: empty.status?.indicator) == .unknown)
    }

    // MARK: - Providers

    private struct NoCredentials: ClaudeCredentialReading {
        func accessToken() throws -> String { throw ProviderError.auth(.missingCredentials) }
    }

    private func claudeProvider(_ behavior: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) -> ClaudeProvider {
        ClaudeProvider(http: StubHTTPClient(behavior: behavior), credentials: NoCredentials(), settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    private func codexProvider(_ behavior: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) -> CodexProvider {
        CodexProvider(http: StubHTTPClient(behavior: behavior), auth: NoCodexCredentials(), settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    @Test func claudeHitsStatusPageWithFixtureBody() async throws {
        let captured = URLCapture()
        let body = try fixtureData("statuspage-claude.json")
        let provider = claudeProvider { req in
            captured.record(req.url)
            return response(200, for: req.url!, body: body)
        }
        #expect(await provider.statusPage() == .operational)
        #expect(captured.urls == [URL(string: "https://status.claude.com/api/v2/status.json")])
    }

    @Test func codexHitsStatusPageWithMinor() async throws {
        let captured = URLCapture()
        let provider = codexProvider { req in
            captured.record(req.url)
            return response(200, for: req.url!, body: Data(#"{"status":{"indicator":"minor"}}"#.utf8))
        }
        #expect(await provider.statusPage() == .degraded)
        #expect(captured.urls == [URL(string: "https://status.openai.com/api/v2/status.json")])
    }

    @Test func providerSwallowsEveryFailure() async {
        let throwing = claudeProvider { _ in throw ProviderError.network }
        #expect(await throwing.statusPage() == .unknown)

        let http500 = claudeProvider { req in response(500, for: req.url!) }
        #expect(await http500.statusPage() == .unknown)

        let garbage = codexProvider { req in response(200, for: req.url!, body: Data("nope {{".utf8)) }
        #expect(await garbage.statusPage() == .unknown)
    }

    // MARK: - PollScheduler wiring

    @Test func successfulStatusLandsInSnapshotAndStore() async throws {
        let clock = ManualClock()
        let writer = SpyStatusWriter()
        let provider = StatusProvider(
            id: .claude, windows: [UsageWindow(name: .primary, usedPercent: 10, windowSeconds: 18_000, resetsAt: nil, fetchedAt: Date())],
            statusResult: .success(.majorDisruption))
        let scheduler = PollScheduler(providers: [provider], writer: writer, settings: makeProberSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("status recorded") { await writer.statusRecords.count == 1 }
        let snapshots = await scheduler.snapshots()
        #expect(snapshots[.claude]?.officialStatus == .majorDisruption)
        #expect(snapshots[.claude]?.lastError == nil)  // status trouble never taints limits
    }

    @Test func failingStatusKeepsLimitsGreenAndStoresNothing() async throws {
        let clock = ManualClock()
        let writer = SpyStatusWriter()
        let provider = StatusProvider(
            id: .claude, windows: [UsageWindow(name: .primary, usedPercent: 10, windowSeconds: 18_000, resetsAt: nil, fetchedAt: Date())],
            statusResult: .failure(.network))
        let scheduler = PollScheduler(providers: [provider], writer: writer, settings: makeProberSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("limits recorded") { await writer.limitsRecords.count == 1 }
        let snapshots = await scheduler.snapshots()
        #expect(snapshots[.claude]?.officialStatus == nil)
        #expect(snapshots[.claude]?.windows.count == 1)
        #expect(snapshots[.claude]?.lastError == nil)
        #expect(await writer.statusRecords.isEmpty)
    }
}

// MARK: - Test doubles (shared with PollScheduler tests' patterns)

final class URLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL?] = []
    func record(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(url)
    }
    var urls: [URL?] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

struct NoCodexCredentials: CodexAuthReading {
    func tokens() throws -> CodexTokens { throw ProviderError.auth(.missingCredentials) }
}

private actor SpyStatusWriter: LimitsWriting {
    private(set) var limitsRecords: [StoreRecord] = []
    private(set) var statusRecords: [StoreRecord] = []
    func append(_ record: StoreRecord) async throws {
        if case .status = record { statusRecords.append(record) }
        else { limitsRecords.append(record) }
    }
}

private struct StatusProvider: Provider {
    let id: ProviderID
    let windows: [UsageWindow]
    let statusResult: Result<StatusPageState, ProviderError>
    func fetchLimits() async throws -> [UsageWindow] { windows }
    func statusPage() async throws -> StatusPageState { try statusResult.get() }
    nonisolated var sessionLogPaths: [URL] { [] }
}

private func makeProberSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "StatusPageTests.\(UUID().uuidString)")!)
}
