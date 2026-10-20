import Foundation

/// Codex (ChatGPT subscription) provider — the allowance GPT-6 Astra draws
/// from. Limits come from the Codex usage endpoint using the OAuth tokens the
/// Codex CLI keeps in `~/.codex/auth.json`. `probe`/`statusPage` arrive with
/// M3; OAuth refresh is an M3 task too (on expiry the UI says "run `codex`
/// once", per the plan's deviation note from spec §6.2).
public struct CodexProvider: Provider {
    public let id: ProviderID = .codex

    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!

    private let http: any HTTPClient
    private let auth: any CodexAuthReading
    private let settings: AppSettings

    public init(http: any HTTPClient, auth: any CodexAuthReading, settings: AppSettings) {
        self.http = http
        self.auth = auth
        self.settings = settings
    }

    public func fetchLimits() async throws -> [UsageWindow] {
        let tokens = try auth.tokens()
        var headers = ["Authorization": "Bearer \(tokens.accessToken)"]
        if let accountId = tokens.accountId {
            headers["chatgpt-account-id"] = accountId
        }

        let request = EndpointRequest(url: Self.usageURL, headers: headers)
        let dto = try await fetchJSON(CodexUsageResponse.self, request, client: http)

        var entries: [(window: WindowName, payload: CodexUsageResponse.WindowPayload)] = []
        if let primary = dto.rateLimits?.primaryPayload {
            entries.append((.primary, primary))
        }
        if let secondary = dto.rateLimits?.secondaryPayload {
            entries.append((.secondary, secondary))
        }

        let values = entries.compactMap(\.payload.usedPercent)
        let scale = PercentScale.scale(values: values)
        let fetchedAt = Date()

        return entries.map { entry in
            UsageWindow(
                name: entry.window,
                usedPercent: entry.payload.usedPercent.map { $0 * scale },
                windowSeconds: entry.payload.windowSeconds,
                resetsAt: entry.payload.resetsAtValue?.date,
                fetchedAt: fetchedAt)
        }
    }

    public func probe(_ model: ProbeModel) async throws -> ProbeSample {
        throw ProviderError.unimplemented
    }

    public func statusPage() async throws -> StatusPageState {
        .unknown
    }

    public var sessionLogPaths: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")]
    }
}

struct CodexUsageResponse: Decodable {
    let rateLimits: RateLimits?

    private enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
        case rateLimit = "rate_limit"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // try?-wrapped per alias so a wrong-shaped candidate falls through
        // to the next spelling instead of aborting the document.
        // Live endpoint (Task 6 spike) reports singular `rate_limit`; the
        // plural spelling from early third-party docs stays as an alias.
        if let singular = try? container.decodeIfPresent(RateLimits.self, forKey: .rateLimit) {
            rateLimits = singular
        } else {
            rateLimits = try? container.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
        }
    }

    struct RateLimits: Decodable {
        let primaryPayload: WindowPayload?
        let secondaryPayload: WindowPayload?

        private enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case primary
            case secondaryWindow = "secondary_window"
            case secondary
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // try?-wrapped per alias: a wrong-shaped candidate falls through.
            if let planned = try? container.decodeIfPresent(WindowPayload.self, forKey: .primaryWindow) {
                primaryPayload = planned
            } else {
                primaryPayload = try? container.decodeIfPresent(WindowPayload.self, forKey: .primary)
            }
            if let planned = try? container.decodeIfPresent(WindowPayload.self, forKey: .secondaryWindow) {
                secondaryPayload = planned
            } else {
                secondaryPayload = try? container.decodeIfPresent(WindowPayload.self, forKey: .secondary)
            }
        }
    }

    struct WindowPayload: Decodable {
        let usedPercent: Double?
        let windowSeconds: Int?
        let resetsAtValue: FlexibleDateValue?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = lenientDouble(container, .usedPercent)
            windowSeconds = lenientInt(container, .windowSeconds)
            // Live shape (Task 6 spike) uses `reset_at` (epoch seconds);
            // `resets_at` stays as an alias.
            resetsAtValue =
                try container.decodeIfPresent(FlexibleDateValue.self, forKey: .resetAt)
                ?? container.decodeIfPresent(FlexibleDateValue.self, forKey: .resetsAt)
        }
    }
}
