import Foundation

/// Claude (Claude Code subscription) provider. Limits come from the OAuth
/// usage endpoint using the token Claude Code keeps in the Keychain.
/// `probe`/`statusPage` arrive with M3.
public struct ClaudeProvider: Provider {
    public let id: ProviderID = .claude

    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let oauthBetaHeader = "oauth-2025-04-20"  // Task 6 spike may revise

    private let http: any HTTPClient
    private let credentials: any ClaudeCredentialReading
    private let settings: AppSettings

    public init(http: any HTTPClient, credentials: any ClaudeCredentialReading, settings: AppSettings) {
        self.http = http
        self.credentials = credentials
        self.settings = settings
    }

    public func fetchLimits() async throws -> [UsageWindow] {
        let token = try credentials.accessToken()
        let request = EndpointRequest(
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": Self.oauthBetaHeader,
            ])
        let dto = try await fetchJSON(ClaudeUsageResponse.self, request, client: http)

        var entries: [(window: WindowName, payload: ClaudeUsageResponse.WindowPayload, seconds: Int)] = []
        if let fiveHour = dto.fiveHour {
            entries.append((.fiveHour, fiveHour, 18_000))
        }
        if let sevenDay = dto.sevenDay {
            entries.append((.sevenDay, sevenDay, 604_800))
        }

        let values = entries.compactMap(\.payload.utilization)
        let scale = PercentScale.scale(values: values)
        let fetchedAt = Date()

        return entries.map { entry in
            UsageWindow(
                name: entry.window,
                usedPercent: entry.payload.utilization.map { $0 * scale },
                windowSeconds: entry.seconds,
                resetsAt: entry.payload.resetsAtValue?.date,
                fetchedAt: fetchedAt)
        }
    }

    public func statusPage() async throws -> StatusPageState {
        .unknown
    }

    public var sessionLogPaths: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")]
    }
}

struct ClaudeUsageResponse: Decodable {
    let fiveHour: WindowPayload?
    let sevenDay: WindowPayload?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct WindowPayload: Decodable {
        let utilization: Double?
        let resetsAtValue: FlexibleDateValue?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAtValue = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Lenient like Codex's: a string-typed "42.5" nil-degrades to a
            // value, not to a whole-document decoding failure (Review Focus).
            utilization = lenientDouble(container, .utilization)
            resetsAtValue = try container.decodeIfPresent(
                FlexibleDateValue.self, forKey: .resetsAtValue)
        }
    }
}
