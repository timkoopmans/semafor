import Foundation

/// Verdict/baseline thresholds, all sourced from `AppSettings` (spec §8).
/// The MAD floors keep z-scores finite when a segment's spread collapses.
public struct Thresholds: Equatable, Sendable {
    public let zWarn: Double
    public let zCrawl: Double
    public let consecutiveN: Int
    public let busyPercent: Double
    public let limitedPercent: Double
    public let paceDeltaPoints: Double
    public let baselineMinSamples: Int
    public let baselineDefaultTTFT: Double
    public let baselineDefaultTokPerSec: Double
    public let madFloorTTFT: Double
    public let madFloorTokPerSec: Double
    public let controlBadLatency: TimeInterval
    public let controlRecentCount: Int
    /// Probe rules ignore samples older than this (spec §8.2 freshness).
    public let sampleRecency: TimeInterval

    public init(
        zWarn: Double,
        zCrawl: Double,
        consecutiveN: Int,
        busyPercent: Double,
        limitedPercent: Double,
        paceDeltaPoints: Double,
        baselineMinSamples: Int,
        baselineDefaultTTFT: Double,
        baselineDefaultTokPerSec: Double,
        madFloorTTFT: Double = 0.25,
        madFloorTokPerSec: Double = 2,
        controlBadLatency: TimeInterval = 5,
        controlRecentCount: Int = 3,
        sampleRecency: TimeInterval = 1800
    ) {
        self.zWarn = zWarn
        self.zCrawl = zCrawl
        self.consecutiveN = consecutiveN
        self.busyPercent = busyPercent
        self.limitedPercent = limitedPercent
        self.paceDeltaPoints = paceDeltaPoints
        self.baselineMinSamples = baselineMinSamples
        self.baselineDefaultTTFT = baselineDefaultTTFT
        self.baselineDefaultTokPerSec = baselineDefaultTokPerSec
        self.madFloorTTFT = madFloorTTFT
        self.madFloorTokPerSec = madFloorTokPerSec
        self.controlBadLatency = controlBadLatency
        self.controlRecentCount = controlRecentCount
        self.sampleRecency = sampleRecency
    }
}

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
        static let scanIntervalSeconds = "scanIntervalSeconds"
        static let backfillDays = "backfillDays"
        static let sampleRecencyMinutes = "sampleRecencyMinutes"
        static let controlProbeEnabled = "controlProbeEnabled"
        static let controlIntervalMinutes = "controlIntervalMinutes"
        static let zWarn = "zWarn"
        static let zCrawl = "zCrawl"
        static let consecutiveProbeN = "consecutiveProbeN"
        static let busyPercent = "busyPercent"
        static let limitedPercent = "limitedPercent"
        static let paceDeltaPoints = "paceDeltaPoints"
        static let baselineMinSamples = "baselineMinSamples"
        static let baselineDefaultTTFT = "baselineDefaultTTFT"
        static let baselineDefaultTokPerSec = "baselineDefaultTokPerSec"
        static let halEnabled = "hal.enabled"
        static let halBaseURL = "hal.baseURL"
        static let halModelName = "hal.modelName"
        static let halDbPath = "hal.dbPath"
        static let launchAtLogin = "launchAtLogin"
    }

    /// Value get/set helper: UserDefaults stores untyped objects, so every
    /// key follows the same read-with-default / write pattern.
    private func value<T>(_ key: String, _ cast: (Any) -> T?, _ fallback: T) -> T {
        (defaults.object(forKey: key)).flatMap(cast) ?? fallback
    }

    public var pollIntervalMinutes: Int {
        get { value(Key.pollIntervalMinutes, { $0 as? Int }, 5) }
        set { defaults.set(newValue, forKey: Key.pollIntervalMinutes) }
    }

    public var scanIntervalSeconds: Int {
        get { value(Key.scanIntervalSeconds, { $0 as? Int }, 60) }
        set { defaults.set(newValue, forKey: Key.scanIntervalSeconds) }
    }

    public var backfillDays: Int {
        get { value(Key.backfillDays, { $0 as? Int }, 7) }
        set { defaults.set(newValue, forKey: Key.backfillDays) }
    }

    public var sampleRecencyMinutes: Int {
        get { value(Key.sampleRecencyMinutes, { $0 as? Int }, 30) }
        set { defaults.set(newValue, forKey: Key.sampleRecencyMinutes) }
    }

    public var controlProbeEnabled: Bool {
        get { value(Key.controlProbeEnabled, { $0 as? Bool }, true) }
        set { defaults.set(newValue, forKey: Key.controlProbeEnabled) }
    }

    public var controlIntervalMinutes: Int {
        get { value(Key.controlIntervalMinutes, { $0 as? Int }, 5) }
        set { defaults.set(newValue, forKey: Key.controlIntervalMinutes) }
    }

    public var zWarn: Double {
        get { value(Key.zWarn, { ($0 as? NSNumber)?.doubleValue }, 3) }
        set { defaults.set(newValue, forKey: Key.zWarn) }
    }

    public var zCrawl: Double {
        get { value(Key.zCrawl, { ($0 as? NSNumber)?.doubleValue }, 6) }
        set { defaults.set(newValue, forKey: Key.zCrawl) }
    }

    public var consecutiveProbeN: Int {
        get { value(Key.consecutiveProbeN, { $0 as? Int }, 3) }
        set { defaults.set(newValue, forKey: Key.consecutiveProbeN) }
    }

    public var busyPercent: Double {
        get { value(Key.busyPercent, { ($0 as? NSNumber)?.doubleValue }, 80) }
        set { defaults.set(newValue, forKey: Key.busyPercent) }
    }

    public var limitedPercent: Double {
        get { value(Key.limitedPercent, { ($0 as? NSNumber)?.doubleValue }, 98) }
        set { defaults.set(newValue, forKey: Key.limitedPercent) }
    }

    public var paceDeltaPoints: Double {
        get { value(Key.paceDeltaPoints, { ($0 as? NSNumber)?.doubleValue }, 15) }
        set { defaults.set(newValue, forKey: Key.paceDeltaPoints) }
    }

    public var baselineMinSamples: Int {
        get { value(Key.baselineMinSamples, { $0 as? Int }, 20) }
        set { defaults.set(newValue, forKey: Key.baselineMinSamples) }
    }

    public var baselineDefaultTTFT: Double {
        get { value(Key.baselineDefaultTTFT, { ($0 as? NSNumber)?.doubleValue }, 8) }
        set { defaults.set(newValue, forKey: Key.baselineDefaultTTFT) }
    }

    public var baselineDefaultTokPerSec: Double {
        get { value(Key.baselineDefaultTokPerSec, { ($0 as? NSNumber)?.doubleValue }, 20) }
        set { defaults.set(newValue, forKey: Key.baselineDefaultTokPerSec) }
    }

    public var halEnabled: Bool {
        get { value(Key.halEnabled, { $0 as? Bool }, true) }
        set { defaults.set(newValue, forKey: Key.halEnabled) }
    }

    public var halBaseURL: String {
        get { value(Key.halBaseURL, { $0 as? String }, "http://hal:8000/v1") }
        set { defaults.set(newValue, forKey: Key.halBaseURL) }
    }

    public var halModelName: String {
        get { value(Key.halModelName, { $0 as? String }, "Qwen3.8-Flash-Next") }
        set { defaults.set(newValue, forKey: Key.halModelName) }
    }

    /// Empty means the default OpenCode database location.
    public var halDbPath: String {
        get { value(Key.halDbPath, { $0 as? String }, "") }
        set { defaults.set(newValue, forKey: Key.halDbPath) }
    }

    public var launchAtLogin: Bool {
        get { value(Key.launchAtLogin, { $0 as? Bool }, false) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    public var thresholds: Thresholds {
        Thresholds(
            zWarn: zWarn,
            zCrawl: zCrawl,
            consecutiveN: consecutiveProbeN,
            busyPercent: busyPercent,
            limitedPercent: limitedPercent,
            paceDeltaPoints: paceDeltaPoints,
            baselineMinSamples: baselineMinSamples,
            baselineDefaultTTFT: baselineDefaultTTFT,
            baselineDefaultTokPerSec: baselineDefaultTokPerSec,
            sampleRecency: TimeInterval(sampleRecencyMinutes) * 60)
    }
}
