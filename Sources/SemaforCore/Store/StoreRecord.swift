import Foundation

/// One line in the JSONL sample store. Probe/status/capacity variants arrive
/// with M3; encoded as one JSON object per line, type-tagged.
public enum StoreRecord: Codable, Equatable, Sendable {
    case limits(ProviderID, [UsageWindow], fetchedAt: Date)
}

/// Destination for scheduler writes; `SampleStore` conforms in production,
/// spies in tests.
public protocol LimitsWriting: Sendable {
    func append(_ record: StoreRecord) async throws
}
