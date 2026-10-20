import Foundation

/// One line in the JSONL sample store. Probe/status/capacity variants arrive
/// with M3; encoded as one JSON object per line, type-tagged, dates as
/// ISO8601 (decoding also accepts the numeric form written before this fix).
public enum StoreRecord: Codable, Equatable, Sendable {
    case limits(ProviderID, [UsageWindow], fetchedAt: Date)

    private enum RootKeys: String, CodingKey { case limits }
    private enum PayloadKeys: String, CodingKey {
        case provider = "_0"
        case windows = "_1"
        case fetchedAt
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let payload = try root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .limits)
        let provider = try payload.decode(ProviderID.self, forKey: .provider)
        let windows = try payload.decode([UsageWindow].self, forKey: .windows)
        let fetched = try payload.decode(FlexibleFetchedAt.self, forKey: .fetchedAt)
        self = .limits(provider, windows, fetchedAt: fetched.date)
    }

    public func encode(to encoder: any Encoder) throws {
        var root = encoder.container(keyedBy: RootKeys.self)
        switch self {
        case .limits(let provider, let windows, let fetchedAt):
            var payload = root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .limits)
            try payload.encode(provider, forKey: .provider)
            try payload.encode(windows, forKey: .windows)
            try payload.encode(StoredDate(fetchedAt), forKey: .fetchedAt)
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

private struct FlexibleFetchedAt: Decodable {
    let date: Date
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
