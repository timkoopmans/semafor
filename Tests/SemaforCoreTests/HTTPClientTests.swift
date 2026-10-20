import Foundation
import Testing

@testable import SemaforCore

struct StubHTTPClient: HTTPClient {
    let behavior: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await behavior(request)
    }
}

private final class RequestBox: @unchecked Sendable {
    var last: URLRequest?
}

private func response(_ code: Int, for url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private struct Payload: Codable, Equatable {
    let usedPercent: Double
}

@Suite("fetchJSON")
struct FetchJSONTests {
    private let url = URL(string: "https://example.test/usage")!

    @Test func decodesSuccessfulResponse() async throws {
        let client = StubHTTPClient { _ in (Data(#"{"usedPercent":42.5}"#.utf8), response(200, for: url)) }
        let payload = try await fetchJSON(Payload.self, EndpointRequest(url: url), client: client)
        #expect(payload == Payload(usedPercent: 42.5))
    }

    @Test func unauthorizedMapsToExpiredAuth() async {
        let client = StubHTTPClient { _ in (Data(), response(401, for: url)) }
        await #expect(throws: ProviderError.auth(.expiredCredentials)) {
            _ = try await fetchJSON(Payload.self, EndpointRequest(url: url), client: client)
        }
    }

    @Test func forbiddenAlsoMapsToExpiredAuth() async {
        let client = StubHTTPClient { _ in (Data(), response(403, for: url)) }
        await #expect(throws: ProviderError.auth(.expiredCredentials)) {
            _ = try await fetchJSON(Payload.self, EndpointRequest(url: url), client: client)
        }
    }

    @Test func otherErrorStatusesMapToHTTP() async {
        let client = StubHTTPClient { _ in (Data(), response(429, for: url)) }
        await #expect(throws: ProviderError.http(status: 429)) {
            _ = try await fetchJSON(Payload.self, EndpointRequest(url: url), client: client)
        }
    }

    @Test func transportFailuresMapToNetwork() async {
        let client = StubHTTPClient { _ in throw URLError(.timedOut) }
        await #expect(throws: ProviderError.network) {
            _ = try await fetchJSON(Payload.self, EndpointRequest(url: url), client: client)
        }
    }

    @Test func malformedBodyMapsToDecoding() async {
        let client = StubHTTPClient { _ in (Data("not json".utf8), response(200, for: url)) }
        do {
            _ = try await fetchJSON(Payload.self, EndpointRequest(url: url), client: client)
            Issue.record("expected a throw")
        } catch let error as ProviderError {
            if case .decoding = error {} else {
                Issue.record("expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func injectsDefaultUserAgentButRespectsOverride() async throws {
        let box = RequestBox()
        let client = StubHTTPClient { request in
            box.last = request
            return (Data(#"{"usedPercent":1}"#.utf8), response(200, for: url))
        }
        _ = try await fetchJSON(Payload.self, EndpointRequest(url: url), client: client)
        #expect(box.last?.value(forHTTPHeaderField: "User-Agent")
            == "Semafor/0.1 (personal menu bar monitor)")

        _ = try await fetchJSON(
            Payload.self,
            EndpointRequest(url: url, headers: ["User-Agent": "Custom"]),
            client: client)
        #expect(box.last?.value(forHTTPHeaderField: "User-Agent") == "Custom")
    }
}

@Suite("redact")
struct RedactTests {
    @Test func hidesBearerAndAPIKeyAndAccountMaterial() {
        let text = """
        authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
        chatgpt-account-id: acct-abc123
        key: sk-ant-api03-NOtAR-eALsEcRet-faKe-fOrTeStS-oNlY
        """
        let redacted = redact(text)
        #expect(!redacted.contains("eyJhbGci"))
        #expect(!redacted.contains("acct-abc123"))
        #expect(!redacted.contains("sk-ant-api03"))
        #expect(redacted.contains("[redacted]"))
    }

    @Test func leavesBenignTextAlone() {
        #expect(redact("weekly window gone ~Thu 14:00") == "weekly window gone ~Thu 14:00")
    }
}
