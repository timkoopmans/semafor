import Foundation

/// Decodes date fields that arrive as ISO8601 strings *or* epoch seconds,
/// and degrades to `nil` rather than failing the whole payload decode when a
/// provider changes its date format (endpoint drift is a Review Focus class).
struct FlexibleDateValue: Decodable, Sendable {
    let date: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
            return
        }
        if let text = try? container.decode(String.self) {
            if let seconds = Double(text) {
                date = Date(timeIntervalSince1970: seconds)
                return
            }
            date = Self.parsed(text)
            return
        }
        date = nil
    }

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

    private static func parsed(_ text: String) -> Date? {
        isoWithFraction.date(from: text) ?? iso.date(from: text)
    }
}
