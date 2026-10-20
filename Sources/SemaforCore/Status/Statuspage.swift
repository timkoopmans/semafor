import Foundation

/// Statuspage.io `/api/v2/status.json` mapping (both status feeds speak it).
public enum StatuspageMapping {
    public static func state(indicator: String?) -> StatusPageState {
        switch indicator {
        case "none": return .operational
        case "minor": return .degraded
        case "major", "critical": return .majorDisruption
        default: return .unknown
        }
    }
}

/// Permissive: any shape that at least lexes decodes; everything optional
/// all the way down to `status.indicator` (spec §8.2 wants "unknown", never
/// a crash, from an unexpected feed).
public struct StatuspageDTO: Decodable, Sendable {
    public struct Status: Decodable, Sendable {
        public let indicator: String?
    }

    public let status: Status?
}

/// Shared fetch: any transport/decoding failure collapses to `.unknown`
/// (status pages are a corroborating signal, not a dependency).
func fetchStatuspage(from url: URL, http: any HTTPClient) async -> StatusPageState {
    do {
        let dto = try await fetchJSON(
            StatuspageDTO.self, EndpointRequest(url: url, timeout: 10), client: http)
        return StatuspageMapping.state(indicator: dto.status?.indicator)
    } catch {
        return .unknown
    }
}
