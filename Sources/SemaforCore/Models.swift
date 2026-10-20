import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Single source of truth for the menu-bar glyph (spec §9).
    public var menuGlyph: String {
        switch self {
        case .claude: return "✳"
        case .codex: return "⬡"
        }
    }
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
}

public enum ProbeOutcome: String, Codable, Equatable, Sendable {
    case ok
    case timeout
    case streamFailure
    case authError
}

/// One passive measurement derived from a provider's own session logs
/// (spec §5.1/§6). Dates travel as ISO8601 strings like `UsageWindow`.
public struct ProbeSample: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let model: String
    /// Dedupe key `"<fileName>#<requestRef|turnId>"` (spec §7).
    public let sessionKey: String
    public let ttft: TimeInterval?
    public let duration: TimeInterval?
    public let tokensPerSecond: Double?
    /// Output tokens for the call (Claude: final cumulative usage; Codex:
    /// accepted burst total). nil when unmeasured — never a fake zero.
    public let tokens: Int?
    public let outcome: ProbeOutcome
    /// Request/turn start.
    public let timestamp: Date

    public init(
        provider: ProviderID,
        model: String,
        sessionKey: String,
        ttft: TimeInterval?,
        duration: TimeInterval?,
        tokensPerSecond: Double?,
        tokens: Int? = nil,
        outcome: ProbeOutcome,
        timestamp: Date
    ) {
        self.provider = provider
        self.model = model
        self.sessionKey = sessionKey
        self.ttft = ttft
        self.duration = duration
        self.tokensPerSecond = tokensPerSecond
        self.tokens = tokens
        self.outcome = outcome
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, sessionKey, ttft, duration, tokensPerSecond, tokens, outcome, timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        ttft = try container.decodeIfPresent(Double.self, forKey: .ttft)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        tokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .tokensPerSecond)
        tokens = try container.decodeIfPresent(Int.self, forKey: .tokens)
        outcome = try container.decode(ProbeOutcome.self, forKey: .outcome)
        let text = try container.decode(String.self, forKey: .timestamp)
        guard let date = StoreDateCoding.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: container, debugDescription: "unparseable date: \(text)")
        }
        timestamp = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(ttft, forKey: .ttft)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(tokensPerSecond, forKey: .tokensPerSecond)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(StoreDateCoding.render(timestamp), forKey: .timestamp)
    }
}

/// Verdict rank order doubles as priority (spec §8.2).
public enum ProviderState: Int, Codable, Comparable, Sendable {
    case ok = 0
    case busy
    case degraded
    case crawling
    case limited
    case unknown

    public static func < (lhs: ProviderState, rhs: ProviderState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One rule that fired inside a verdict, carrying the numbers (§8.2: the
/// popover always shows *why*).
public struct VerdictReason: Codable, Equatable, Sendable {
    public let code: String
    public let detail: String

    public init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }
}

public struct Verdict: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let state: ProviderState
    public let reasons: [VerdictReason]
    public let computedAt: Date

    public init(
        provider: ProviderID,
        state: ProviderState,
        reasons: [VerdictReason],
        computedAt: Date
    ) {
        self.provider = provider
        self.state = state
        self.reasons = reasons
        self.computedAt = computedAt
    }
}

/// One HTTP control-probe outcome (spec §7).
public struct ControlSample: Codable, Equatable, Sendable {
    public let provider: ProviderID
    /// nil = the request failed or returned >= 400.
    public let latency: TimeInterval?
    public let timestamp: Date

    public init(provider: ProviderID, latency: TimeInterval?, timestamp: Date) {
        self.provider = provider
        self.latency = latency
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case provider, latency, timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        latency = try container.decodeIfPresent(Double.self, forKey: .latency)
        let text = try container.decode(String.self, forKey: .timestamp)
        guard let date = StoreDateCoding.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: container, debugDescription: "unparseable date: \(text)")
        }
        timestamp = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(latency, forKey: .latency)
        try container.encode(StoreDateCoding.render(timestamp), forKey: .timestamp)
    }
}

/// A capacity-event marker sniffed from CLI session logs. Carried in M3
/// (verdict inputs); emitted by the M4 capacity extractor (spec §5).
public struct CapacityEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case rateLimit429
        case planLimit
        case overloaded
        case stall
    }

    public let provider: ProviderID
    public let kind: Kind
    public let detail: String?
    public let at: Date

    public init(provider: ProviderID, kind: Kind, detail: String?, at: Date) {
        self.provider = provider
        self.kind = kind
        self.detail = detail
        self.at = at
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
    /// Official status page seen on the last successful limits poll; nil
    /// when the feed failed (spec §8.2 divergence input).
    public let officialStatus: StatusPageState?

    public init(
        providerID: ProviderID,
        windows: [UsageWindow],
        fetchedAt: Date,
        lastError: ProviderError?,
        officialStatus: StatusPageState? = nil
    ) {
        self.providerID = providerID
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.lastError = lastError
        self.officialStatus = officialStatus
    }
}
