import Foundation

/// One control measurement per provider: a static asset GET whose latency
/// separates "my network / DNS / TLS is broken" from "their model is slow"
/// (spec §6.3). Never carries credentials.
public protocol ControlProbing: Sendable {
    func measure(_ id: ProviderID) async -> ControlSample
}

public struct ControlProbe: ControlProbing {
    private static let timeout: TimeInterval = 10
    private static let endpoints: [ProviderID: URL] = [
        .claude: URL(string: "https://claude.ai/robots.txt")!,
        .codex: URL(string: "https://chatgpt.com/robots.txt")!,
    ]

    private let http: any HTTPClient
    private let dateNow: @Sendable () -> Date

    public init(http: any HTTPClient, dateNow: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.dateNow = dateNow
    }

    /// Latency in wall seconds; nil on any transport error or status ≥ 400.
    public func measure(_ id: ProviderID) async -> ControlSample {
        let timestamp = dateNow()
        guard let url = Self.endpoints[id] else {
            return ControlSample(provider: id, latency: nil, timestamp: timestamp)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue(semaforUserAgent, forHTTPHeaderField: "User-Agent")

        let start = dateNow()
        do {
            let (_, response) = try await http.data(for: request)
            let end = dateNow()
            guard (200..<400).contains(response.statusCode) else {
                return ControlSample(provider: id, latency: nil, timestamp: timestamp)
            }
            return ControlSample(
                provider: id, latency: max(0, end.timeIntervalSince(start)), timestamp: timestamp)
        } catch {
            return ControlSample(provider: id, latency: nil, timestamp: timestamp)
        }
    }
}

extension ControlSample {
    /// A control is "bad" when it failed or took longer than `threshold` —
    /// verdicts then blame the network, not the provider (spec §8.2).
    public func isBad(threshold: TimeInterval) -> Bool {
        guard let latency else { return true }
        return latency > threshold
    }
}
