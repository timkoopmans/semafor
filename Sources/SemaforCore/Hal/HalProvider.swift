import Foundation

/// HAL (personal OpenAI-compatible router) provider. There are no usage
/// limits to read, so the "poll" is a lightweight /models health probe whose
/// only output is the served-model pick shown in the menu bar (spec §6).
/// Polling is gated by `settings.halEnabled`.
public final class HalProvider: Provider, @unchecked Sendable {
    // Mutable served-model state; @unchecked Sendable is sanctioned only
    // because every read and write below goes through this lock, since
    // PollScheduler may drive fetches concurrently (loop tick + refresh).
    private let lock = NSLock()
    private var lastServedModel: String?

    private let http: any HTTPClient
    private let settings: AppSettings

    public let id: ProviderID = .hal

    public var pollingEnabled: Bool { settings.halEnabled }

    public init(http: any HTTPClient, settings: AppSettings) {
        self.http = http
        self.settings = settings
    }

    /// Last successful pick; kept across failures so the menu bar keeps a
    /// stale-but-honest model name while HAL is briefly unreachable.
    public func servedModel() async -> String? {
        lock.withLockUnsafe { lastServedModel }
    }

    public func fetchLimits() async throws -> [UsageWindow] {
        guard let url = URL(string: "\(trimTrailingSlash(settings.halBaseURL))/models") else {
            throw ProviderError.network
        }
        let dto = try await fetchJSON(HalModelsResponse.self, EndpointRequest(url: url), client: http)

        // Exact configured-model match, else whatever the router serves
        // first, else nil; an empty catalogue is a success and records nil
        // (box is up, serving nothing). Only fetch failures keep the old pick.
        let pick = dto.data.first(where: { $0.id == settings.halModelName })?.id ?? dto.data.first?.id
        lock.withLockUnsafe { lastServedModel = pick }
        return []
    }

    public func statusPage() async throws -> StatusPageState {
        .unknown  // self-hosted router: no public status feed, no network call
    }

    public var sessionLogPaths: [URL] { [] }  // sessions come from HalScanner instead
}

/// `{"data":[{"id":...}]}`; extra envelope and row fields are tolerated.
private struct HalModelsResponse: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let id: String
    }
    let data: [Model]
}

func trimTrailingSlash(_ value: String) -> String {
    var value = value[...]
    while value.hasSuffix("/") {
        value = value.dropLast()
    }
    return String(value)
}

private extension NSLock {
    /// `withLock` arrived in newer SDKs than our macOS 14 floor targets;
    /// a sync helper also keeps lock/unlock out of async function bodies.
    func withLockUnsafe<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
