import Foundation

/// Uniform access to one subscription's limits, official status, and local
/// session-log locations. Measurement is passive (spec §6); there is no
/// probe on the protocol.
public protocol Provider: Sendable {
    var id: ProviderID { get }
    func fetchLimits() async throws -> [UsageWindow]
    func statusPage() async throws -> StatusPageState
    var sessionLogPaths: [URL] { get }
}
