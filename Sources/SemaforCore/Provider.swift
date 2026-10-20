import Foundation

/// Uniform access to one subscription's limits, probes, official status, and
/// local CLI session logs. `probe`/`statusPage` are stubbed until M3.
public protocol Provider: Sendable {
    var id: ProviderID { get }
    func fetchLimits() async throws -> [UsageWindow]
    func probe(_ model: ProbeModel) async throws -> ProbeSample
    func statusPage() async throws -> StatusPageState
    var sessionLogPaths: [URL] { get }
}
