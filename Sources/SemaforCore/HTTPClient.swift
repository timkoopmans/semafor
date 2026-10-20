import Foundation

/// Seam for all outbound HTTP so providers can be tested against stubs.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.network
        }
        return (data, httpResponse)
    }
}

public struct EndpointRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

package let semaforUserAgent = "Semafor/0.1 (personal menu bar monitor)"

/// GET/POST a provider endpoint, map transport/status failures to typed
/// `ProviderError`s, and decode the body as JSON.
public func fetchJSON<D: Decodable & Sendable>(
    _ type: D.Type,
    _ request: EndpointRequest,
    client: any HTTPClient
) async throws -> D {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.timeoutInterval = request.timeout
    urlRequest.httpBody = request.body
    urlRequest.setValue(semaforUserAgent, forHTTPHeaderField: "User-Agent")
    for (field, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: field)
    }

    let data: Data
    let response: HTTPURLResponse
    do {
        (data, response) = try await client.data(for: urlRequest)
    } catch let error as ProviderError {
        throw error
    } catch {
        throw ProviderError.network
    }

    try mapResponseToError(response)

    do {
        return try JSONDecoder().decode(D.self, from: data)
    } catch {
        throw ProviderError.decoding(String(describing: error))
    }
}

func mapResponseToError(_ response: HTTPURLResponse) throws {
    switch response.statusCode {
    case 200..<300:
        return
    case 401, 403:
        throw ProviderError.auth(.expiredCredentials)
    default:
        throw ProviderError.http(status: response.statusCode)
    }
}

/// Scrub credential material from anything destined for logs or smoke output.
public func redact(_ text: String) -> String {
    var result = text
    for rule in Redactor.rules {
        result = rule.regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: rule.template)
    }
    return result
}

private struct RedactRule: Sendable {
    let regex: NSRegularExpression
    let template: String
}

private enum Redactor {
    nonisolated(unsafe) static let rules: [RedactRule] = [
        // Authorization: Bearer <token>
        rule(#"(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*"#, "Bearer [redacted]"),
        // Anthropic-style API keys
        rule(#"\bsk-ant-[A-Za-z0-9_\-]+\b"#, "[redacted-api-key]"),
        // Bare JWTs (three dot-separated base64url segments)
        rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, "[redacted-jwt]"),
        // ChatGPT account-id header material
        rule(#"(?i)(chatgpt-account-id["'\s]*[:=]["'\s]*)\S+"#, "$1[redacted]"),
    ]

    private static func rule(_ pattern: String, _ template: String) -> RedactRule {
        RedactRule(
            regex: try! NSRegularExpression(pattern: pattern),
            template: template)
    }
}
