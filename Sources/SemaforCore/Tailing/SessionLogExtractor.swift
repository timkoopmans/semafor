import Foundation

/// Shared strict-ISO parsing for session-log timestamps (spec §6); nil for
/// missing/malformed values — extractors skip such lines rather than guess.
enum LogTimeCoding {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: Any?) -> Date? {
        guard let string = text as? String else { return nil }
        return withFraction.date(from: string) ?? plain.date(from: string)
    }
}

/// Incrementally derives `ProbeSample`s from tailed CLI session lines
/// (spec §6/§7). Implementations are pure value types: `ingest` accumulates,
/// `finish` emits everything that is complete as of `now` and drops it.
public protocol SessionLogExtracting: Sendable {
    mutating func ingest(_ line: TailedLine)
    mutating func finish(now: Date) -> [ProbeSample]
}
