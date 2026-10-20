import Foundation

/// One line in the JSONL sample store (spec §11). Encoded as one JSON object
/// per line, type-tagged by a single root key; dates as ISO8601 (decoding
/// also accepts the numeric form written before that fix).
public enum StoreRecord: Codable, Equatable, Sendable {
    case limits(ProviderID, [UsageWindow], fetchedAt: Date)
    case probe(ProbeSample)
    case control(ControlSample)
    case status(ProviderID, StatusPageState, fetchedAt: Date)

    private enum RootKeys: String, CodingKey {
        case limits
        case probe
        case control
        case status
    }

    private enum PayloadKeys: String, CodingKey {
        case provider
        case windows
        case fetchedAt
        case legacyProvider = "_0"
        case legacyWindows = "_1"
    }

    private struct StatusPayload: Codable, Equatable {
        let provider: ProviderID
        let state: StatusPageState
        let fetchedAt: FlexibleFetchedAt
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        if root.contains(.limits) {
            let payload = try root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .limits)
            // Named keys; pre-readable-format lines used synthesized _0/_1.
            let provider: ProviderID
            if let named = try? payload.decode(ProviderID.self, forKey: .provider) {
                provider = named
            } else {
                provider = try payload.decode(ProviderID.self, forKey: .legacyProvider)
            }
            let windows: [UsageWindow]
            if let named = try? payload.decode([UsageWindow].self, forKey: .windows) {
                windows = named
            } else {
                windows = try payload.decode([UsageWindow].self, forKey: .legacyWindows)
            }
            let fetched = try payload.decode(FlexibleFetchedAt.self, forKey: .fetchedAt)
            self = .limits(provider, windows, fetchedAt: fetched.date)
        } else if root.contains(.probe) {
            self = .probe(try root.decode(ProbeSample.self, forKey: .probe))
        } else if root.contains(.control) {
            self = .control(try root.decode(ControlSample.self, forKey: .control))
        } else if root.contains(.status) {
            let payload = try root.decode(StatusPayload.self, forKey: .status)
            self = .status(payload.provider, payload.state, fetchedAt: payload.fetchedAt.date)
        } else {
            // Unknown type-tag: throw so the reader's corrupt-line count applies.
            throw DecodingError.keyNotFound(
                RootKeys.limits,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "no known record type key in line"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var root = encoder.container(keyedBy: RootKeys.self)
        switch self {
        case .limits(let provider, let windows, let fetchedAt):
            var payload = root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .limits)
            try payload.encode(provider, forKey: .provider)
            try payload.encode(windows, forKey: .windows)
            try payload.encode(StoredDate(fetchedAt), forKey: .fetchedAt)
        case .probe(let sample):
            try root.encode(sample, forKey: .probe)
        case .control(let sample):
            try root.encode(sample, forKey: .control)
        case .status(let provider, let state, let fetchedAt):
            try root.encode(
                StatusPayload(provider: provider, state: state,
                              fetchedAt: FlexibleFetchedAt(fetchedAt)),
                forKey: .status)
        }
    }
}

private struct StoredDate: Encodable {
    let date: Date
    init(_ date: Date) { self.date = date }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(StoreDateCoding.render(date))
    }
}

struct FlexibleFetchedAt: Codable, Equatable {
    let date: Date
    init(_ date: Date) { self.date = date }
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self), let parsed = StoreDateCoding.parse(text) {
            date = parsed
            return
        }
        if let seconds = try? container.decode(Double.self) {
            // Lines written before record-level dates became ISO8601.
            date = Date(timeIntervalSinceReferenceDate: seconds)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "unparseable fetchedAt")
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(StoreDateCoding.render(date))
    }
}

/// Shared ISO8601 rendering for store-level dates (window-level coding lives
/// in `UsageWindow` itself).
enum StoreDateCoding {
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func render(_ date: Date) -> String { iso.string(from: date) }

    static func parse(_ text: String) -> Date? {
        isoWithFraction.date(from: text) ?? iso.date(from: text)
    }
}

/// Destination for scheduler writes; `SampleStore` conforms in production,
/// spies in tests.
public protocol LimitsWriting: Sendable {
    func append(_ record: StoreRecord) async throws
}
