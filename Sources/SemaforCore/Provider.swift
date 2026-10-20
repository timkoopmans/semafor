import Foundation

/// Uniform access to one subscription's limits, official status, and local
/// session-log locations. Measurement is passive (spec §6); there is no
/// probe on the protocol.
public protocol Provider: Sendable {
    var id: ProviderID { get }
    func fetchLimits() async throws -> [UsageWindow]
    func statusPage() async throws -> StatusPageState
    var sessionLogPaths: [URL] { get }
    /// When false, `PollScheduler` skips this provider entirely (periodic
    /// ticks and manual refresh alike); existing snapshots stay in place.
    var pollingEnabled: Bool { get }
}

extension Provider {
    /// Providers without a user-facing on/off switch always poll.
    public var pollingEnabled: Bool { true }
}
