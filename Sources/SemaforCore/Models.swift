import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

public enum WindowName: String, Codable, Equatable, Sendable {
    case fiveHour
    case sevenDay
    case primary
    case secondary
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let name: WindowName
    public let usedPercent: Double?
    public let windowSeconds: Int?
    public let resetsAt: Date?
    public let fetchedAt: Date

    public init(
        name: WindowName,
        usedPercent: Double?,
        windowSeconds: Int?,
        resetsAt: Date?,
        fetchedAt: Date
    ) {
        self.name = name
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
    }

    // Dates travel as ISO8601 strings so JSONL store contents stay readable
    // and provider-side flexible decoding remains a separate concern.
    nonisolated(unsafe) private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parse(_ text: String) -> Date? {
        iso8601WithFraction.date(from: text) ?? iso8601.date(from: text)
    }

    private static func render(_ date: Date) -> String {
        iso8601.string(from: date)
    }

    private enum CodingKeys: String, CodingKey {
        case name, usedPercent, windowSeconds, resetsAt, fetchedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(WindowName.self, forKey: .name)
        usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
        windowSeconds = try container.decodeIfPresent(Int.self, forKey: .windowSeconds)
        if let text = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            guard let date = Self.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .resetsAt, in: container, debugDescription: "unparseable date: \(text)")
            }
            resetsAt = date
        } else {
            resetsAt = nil
        }
        let fetchedAtText = try container.decode(String.self, forKey: .fetchedAt)
        guard let date = Self.parse(fetchedAtText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fetchedAt, in: container, debugDescription: "unparseable date: \(fetchedAtText)")
        }
        fetchedAt = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        try container.encodeIfPresent(resetsAt.map(Self.render), forKey: .resetsAt)
        try container.encode(Self.render(fetchedAt), forKey: .fetchedAt)
    }
}

public enum AuthReason: String, Codable, Equatable, Sendable {
    case missingCredentials
    case expiredCredentials
}

public enum ProviderError: Error, Equatable, Sendable {
    case auth(AuthReason)
    case http(status: Int)
    case network
    case decoding(String)
    case unimplemented
}

public enum ProbeMode: String, Codable, Equatable, Sendable {
    case standard
    case fast
}

public struct ProbeModel: Codable, Equatable, Sendable {
    public let id: String
    public let mode: ProbeMode

    public init(id: String, mode: ProbeMode) {
        self.id = id
        self.mode = mode
    }
}

public enum ProbeOutcome: Codable, Equatable, Sendable {
    case ok
    case timeout
    case httpError(Int)
    case authError
    case network
}

public struct ProbeSample: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let model: String
    public let mode: ProbeMode
    public let ttft: TimeInterval
    public let tokensPerSecond: Double?
    public let outcome: ProbeOutcome
    public let timestamp: Date

    public init(
        provider: ProviderID,
        model: String,
        mode: ProbeMode,
        ttft: TimeInterval,
        tokensPerSecond: Double?,
        outcome: ProbeOutcome,
        timestamp: Date
    ) {
        self.provider = provider
        self.model = model
        self.mode = mode
        self.ttft = ttft
        self.tokensPerSecond = tokensPerSecond
        self.outcome = outcome
        self.timestamp = timestamp
    }
}

public enum StatusPageState: String, Codable, Equatable, Sendable {
    case operational
    case degraded
    case majorDisruption
    case unknown
}

public struct ProviderSnapshot: Sendable {
    public let providerID: ProviderID
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public let lastError: ProviderError?

    public init(
        providerID: ProviderID,
        windows: [UsageWindow],
        fetchedAt: Date,
        lastError: ProviderError?
    ) {
        self.providerID = providerID
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.lastError = lastError
    }
}
