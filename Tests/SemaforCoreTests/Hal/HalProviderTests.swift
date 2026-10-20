import Foundation
import Testing

@testable import SemaforCore

// MARK: - Stub plumbing (reuses StubHTTPClient from HTTPClientTests)

private enum StubStep: Sendable {
    case json(String, status: Int)
    case networkError
}

/// Consumes scripted steps in order (network error once exhausted) and
/// records the requests the provider actually issued.
private final class ScriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [StubStep]
    private var requests: [URLRequest] = []

    init(_ steps: [StubStep]) {
        self.steps = steps
    }

    func consume(for request: URLRequest) -> StubStep {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return steps.isEmpty ? .networkError : steps.removeFirst()
    }

    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private func halResponse(_ code: Int, for url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func scriptedClient(_ steps: [StubStep]) -> (client: StubHTTPClient, box: ScriptBox) {
    let box = ScriptBox(steps)
    let client = StubHTTPClient { request in
        switch box.consume(for: request) {
        case .json(let body, let status):
            return (Data(body.utf8), halResponse(status, for: request.url!))
        case .networkError:
            throw URLError(.timedOut)
        }
    }
    return (client, box)
}

@Suite("HalProvider")
struct HalProviderTests {
    private func makeSettings(
        baseURL: String = "http://hal.test:8000/v1",
        model: String = "Qwen3.8-Flash-Next"
    ) -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "HalProviderTests.\(UUID().uuidString)")!)
        settings.halBaseURL = baseURL
        settings.halModelName = model
        return settings
    }

    @Test func fetchLimitsSucceedsWithNoWindows() async throws {
        // Unknown extra fields on both the envelope and rows must be tolerated.
        let (client, box) = scriptedClient([
            .json(#"{"object":"list","data":[{"id":"glm-4.6","created":1},{"id":"other"}]}"#, status: 200),
        ])
        let provider = HalProvider(
            http: client,
            settings: makeSettings(baseURL: "http://hal.test:8000/v1/"))  // trailing slash trimmed

        let windows = try await provider.fetchLimits()
        #expect(windows.isEmpty)

        let request = try #require(box.recorded.first)
        #expect(request.url?.absoluteString == "http://hal.test:8000/v1/models")
        #expect(request.httpMethod == "GET")
        // No exact match for the configured model ⇒ first id wins.
        #expect(await provider.servedModel() == "glm-4.6")
    }

    @Test func servedModelPicksExactThenFirstThenNil() async throws {
        let (client, _) = scriptedClient([
            .json(#"{"data":[{"id":"glm-4.6"},{"id":"Qwen3.8-Flash-Next"}]}"#, status: 200),
            .json(#"{"data":[{"id":"deepseek-v3.2"},{"id":"kimi-k2"}]}"#, status: 200),
            .json(#"{"data":[]}"#, status: 200),
            .networkError,
        ])
        let provider = HalProvider(http: client, settings: makeSettings())

        _ = try await provider.fetchLimits()
        #expect(await provider.servedModel() == "Qwen3.8-Flash-Next")  // exact id match wins

        _ = try await provider.fetchLimits()
        #expect(await provider.servedModel() == "deepseek-v3.2")  // no exact match ⇒ first row

        _ = try await provider.fetchLimits()
        #expect(await provider.servedModel() == nil)  // empty data is still a success ⇒ records nil

        await #expect(throws: ProviderError.network) {
            _ = try await provider.fetchLimits()
        }
        #expect(await provider.servedModel() == nil)  // failures keep the last value, never resurrect
    }

    @Test func statusPageIsUnknownWithoutNetwork() async throws {
        let (client, box) = scriptedClient([])  // zero canned responses; any request would throw
        let provider = HalProvider(http: client, settings: makeSettings())

        #expect(try await provider.statusPage() == .unknown)
        #expect(box.recorded.isEmpty)  // proven no network call, not just a value
    }

    @Test func failureKeepsLastServedModel() async throws {
        let (client, _) = scriptedClient([
            .json(#"{"data":[{"id":"glm-4.6"}]}"#, status: 200),
            .networkError,
        ])
        let provider = HalProvider(http: client, settings: makeSettings())

        #expect(await provider.servedModel() == nil)
        _ = try await provider.fetchLimits()
        #expect(await provider.servedModel() == "glm-4.6")

        await #expect(throws: ProviderError.network) {
            _ = try await provider.fetchLimits()
        }
        #expect(await provider.servedModel() == "glm-4.6")  // failures never clear the pick
    }

    @Test func httpStatus500MapsToHttp() async throws {
        let (client, _) = scriptedClient([
            .json("not json", status: 500),
        ])
        let provider = HalProvider(http: client, settings: makeSettings())

        await #expect(throws: ProviderError.http(status: 500)) {
            _ = try await provider.fetchLimits()
        }
        #expect(await provider.servedModel() == nil)  // failed fetch records nothing
    }
}
