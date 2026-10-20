import Foundation

/// Everything the popover renders for one provider. Pure value type so all
/// copy is unit-testable without SwiftUI (spec §9).
public struct ProviderSectionModel: Equatable, Sendable {
    public struct WindowRow: Equatable, Sendable {
        public let label: String
        public let percentText: String
        public let barPercent: Double?
        public let resetsText: String
        public let paceText: String?
        public let dimmed: Bool
    }

    public let providerID: ProviderID
    public let displayName: String
    public let glyph: String
    public let rows: [WindowRow]
    public let headline: String?
    public let statusLine: String
    public let isStale: Bool

    public init(
        snapshot: ProviderSnapshot,
        projections: [WindowName: BurnRateEstimator.Projection],
        now: Date,
        settings: AppSettings,
        pollInterval: TimeInterval
    ) {
        providerID = snapshot.providerID
        displayName = snapshot.providerID.displayName
        glyph = snapshot.providerID.menuGlyph
        let stale = now.timeIntervalSince(snapshot.fetchedAt) > 3 * pollInterval
        isStale = stale

        // Local binding so the map closure doesn't capture half-initialized self.
        let windowRows = snapshot.windows.map { window in
            WindowRow(
                label: Self.label(for: window.name),
                percentText: window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "–",
                barPercent: window.usedPercent,
                resetsText: Self.resetsText(resetsAt: window.resetsAt, now: now),
                paceText: Self.paceText(
                    for: window, now: now, settings: settings),
                dimmed: stale)
        }
        rows = windowRows

        // Longest window present wins the burn-rate headline.
        if snapshot.windows.contains(where: { $0.name == .sevenDay }),
           let projection = projections[.sevenDay]
        {
            headline = projection.headline
        } else if snapshot.windows.contains(where: { $0.name == .secondary }),
                  let projection = projections[.secondary]
        {
            headline = projection.headline
        } else {
            headline = nil
        }

        statusLine = Self.statusLine(for: snapshot)
    }

    // MARK: - Copy

    static func label(for name: WindowName) -> String {
        switch name {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        }
    }

    static func resetsText(resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return "—" }
        let total = Int(resetsAt.timeIntervalSince(now))
        if total < 60 { return "resetting…" }  // imminent or past: window is turning over
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }

    static func paceText(
        for window: UsageWindow, now: Date, settings: AppSettings
    ) -> String? {
        switch BurnRateEstimator.pace(
            usedPercent: window.usedPercent,
            windowSeconds: window.windowSeconds,
            resetsAt: window.resetsAt,
            now: now
        ) {
        case .aheadOfPace(let delta):
            return "ahead of pace (+\(Int(delta.rounded())) pts)"
        case .ok, .notEnoughData:
            return nil
        }
    }

    static func statusLine(for snapshot: ProviderSnapshot) -> String {
        let cli = snapshot.providerID == .claude ? "claude" : "codex"
        switch snapshot.lastError {
        case nil, .unimplemented:
            return ""
        case .auth(.missingCredentials):
            return "Not signed in — run `\(cli)` once"
        case .auth(.expiredCredentials):
            return "Token expired — run `\(cli)` once"
        case .network:
            return "Network unreachable"
        case .http(let status):
            return "Provider API error (\(status))"
        case .decoding:
            return "Unexpected provider response"
        }
    }
}

/// Menu-bar item copy + color, decided from the worst window across all
/// providers (spec §9: one glance tells you the worst situation).
public enum StatusItemModel {
    public enum StatusColor: Equatable, Sendable {
        case green, amber, red, grey
    }

    public struct Result: Equatable, Sendable {
        public let title: String
        public let color: StatusColor
    }

    public static func title(
        for snapshots: [ProviderID: ProviderSnapshot],
        pollInterval: TimeInterval,
        now: Date
    ) -> Result {
        // Codex first in the preference list ⇒ it wins ties: replace only on
        // a strictly greater percent (max(by:) ties are unspecified).
        let preference: [ProviderID] = [.codex, .claude]
        let worst = preference.compactMap { provider -> (ProviderID, Double)? in
            guard let maxPercent = snapshots[provider]?.windows.compactMap(\.usedPercent).max()
            else { return nil }
            return (provider, maxPercent)
        }
        guard !worst.isEmpty else {
            return Result(title: "✳ –", color: colorWithoutData(snapshots))
        }
        var leader = worst[0]
        for candidate in worst.dropFirst() where candidate.1 > leader.1 {
            leader = candidate
        }

        return Result(
            title: "\(leader.0.menuGlyph) \(Int(leader.1.rounded()))%",
            color: color(for: snapshots, worst: leader.1))
    }

    /// Red outranks amber outranks grey, exactly as the plan lists the ladder:
    /// a near-exhausted window stays red even while another provider has an
    /// auth problem (the popover row carries the auth hint).
    private static func color(
        for snapshots: [ProviderID: ProviderSnapshot], worst: Double
    ) -> StatusColor {
        if worst >= 98 { return .red }
        if worst >= 80 { return .amber }
        if snapshots.values.contains(where: { if case .auth = $0.lastError { return true } else { return false } }) {
            return .grey
        }
        return .green
    }

    /// Ladder when no provider reports a usable percent: auth problems or no
    /// snapshots yet are grey; otherwise green (nothing to warn about).
    private static func colorWithoutData(_ snapshots: [ProviderID: ProviderSnapshot]) -> StatusColor {
        if snapshots.isEmpty { return .grey }
        if snapshots.values.contains(where: { if case .auth = $0.lastError { return true } else { return false } }) {
            return .grey
        }
        return .green
    }
}
