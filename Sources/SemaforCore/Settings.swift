import Foundation

/// User-configurable policy, backed by `UserDefaults`.
///
/// All properties are value-typed and `UserDefaults` is internally
/// thread-safe for these reads/writes, so the unchecked `Sendable`
/// conformance is sound — there is no non-serialized composite state.
public final class AppSettings: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let pollIntervalMinutes = "pollIntervalMinutes"
        static let quietHoursEnabled = "quietHoursEnabled"
        static let quietStart = "quietStart"
        static let quietEnd = "quietEnd"
        static let claudeProbeModelID = "claudeProbeModelID"
        static let codexProbeModelID = "codexProbeModelID"
        static let launchAtLogin = "launchAtLogin"
    }

    public var pollIntervalMinutes: Int {
        get { (defaults.object(forKey: Key.pollIntervalMinutes) as? Int) ?? 5 }
        set { defaults.set(newValue, forKey: Key.pollIntervalMinutes) }
    }

    public var quietHoursEnabled: Bool {
        get { (defaults.object(forKey: Key.quietHoursEnabled) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.quietHoursEnabled) }
    }

    public var quietStart: String {
        get { defaults.string(forKey: Key.quietStart) ?? "22:00" }
        set { defaults.set(newValue, forKey: Key.quietStart) }
    }

    public var quietEnd: String {
        get { defaults.string(forKey: Key.quietEnd) ?? "07:00" }
        set { defaults.set(newValue, forKey: Key.quietEnd) }
    }

    public var claudeProbeModelID: String {
        get { defaults.string(forKey: Key.claudeProbeModelID) ?? "" }
        set { defaults.set(newValue, forKey: Key.claudeProbeModelID) }
    }

    public var codexProbeModelID: String {
        get { defaults.string(forKey: Key.codexProbeModelID) ?? "gpt-6-astra" }
        set { defaults.set(newValue, forKey: Key.codexProbeModelID) }
    }

    public var launchAtLogin: Bool {
        get { (defaults.object(forKey: Key.launchAtLogin) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }
}
