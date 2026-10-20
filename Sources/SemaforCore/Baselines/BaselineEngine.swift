import Foundation

/// Segments learned baselines by provider × model × weekend/weekday × 6-hour
/// bucket (spec §8.1): overnight and Friday-night traffic get their own
/// expectations.
public struct BaselineKey: Hashable, Sendable {
    public let provider: ProviderID
    public let model: String
    public let weekend: Bool
    /// Hour of day collapsed to 6-hour buckets: `hour / 6` ⇒ 0…3.
    public let bucket: Int

    public init(provider: ProviderID, model: String, weekend: Bool, bucket: Int) {
        self.provider = provider
        self.model = model
        self.weekend = weekend
        self.bucket = bucket
    }
}

public struct MetricBaseline: Equatable, Sendable {
    public let median: Double
    /// Median absolute deviation from the median; 0 with too few samples or
    /// when the segment's spread collapses (z-scores then apply `madFloor`).
    public let mad: Double
    public let count: Int

    public init(median: Double, mad: Double, count: Int) {
        self.median = median
        self.mad = mad
        self.count = count
    }
}

public struct BaselineSet: Equatable, Sendable {
    public let ttft: MetricBaseline
    public let tokPerSec: MetricBaseline
    /// True only when both metrics reached `baselineMinSamples`; otherwise a
    /// metric falls back to its absolute default (spec §8.1 cold start).
    public let learned: Bool

    public init(ttft: MetricBaseline, tokPerSec: MetricBaseline, learned: Bool) {
        self.ttft = ttft
        self.tokPerSec = tokPerSec
        self.learned = learned
    }
}

public struct BaselineEngine: Sendable {
    private let thresholds: Thresholds
    private let calendar: Calendar

    public init(thresholds: Thresholds, calendar: Calendar = Calendar.current) {
        self.thresholds = thresholds
        self.calendar = calendar
    }

    public func key(at date: Date, provider: ProviderID, model: String) -> BaselineKey {
        let components = calendar.dateComponents([.weekday, .hour], from: date)
        let weekday = components.weekday ?? 1
        let isWeekend = weekday == 1 || weekday == 7  // Sun/Sat in any locale
        return BaselineKey(
            provider: provider, model: model, weekend: isWeekend,
            bucket: (components.hour ?? 0) / 6)
    }

    /// Medians over usable samples matching `key`: `.ok` only, not future,
    /// ttft/token values present per metric. Under `baselineMinSamples` the
    /// metric compares against the absolute default instead.
    public func baseline(for key: BaselineKey, samples: [ProbeSample], now: Date) -> BaselineSet {
        let matching = samples.filter { sample in
            sample.outcome == .ok
                && sample.timestamp <= now
                && self.key(at: sample.timestamp, provider: sample.provider, model: sample.model) == key
        }
        let ttftValues = matching.compactMap(\.ttft)
        let rateValues = matching.compactMap(\.tokensPerSecond)

        let ttftLearned = ttftValues.count >= thresholds.baselineMinSamples
        let rateLearned = rateValues.count >= thresholds.baselineMinSamples
        return BaselineSet(
            ttft: metricBaseline(values: ttftValues, fallbackMedian: thresholds.baselineDefaultTTFT),
            tokPerSec: metricBaseline(values: rateValues, fallbackMedian: thresholds.baselineDefaultTokPerSec),
            learned: ttftLearned && rateLearned)
    }

    /// Robust z-score; the floor keeps it finite when MAD is 0 (spec §8.1).
    public func z(_ x: Double, metric: MetricBaseline, floor: Double) -> Double {
        abs(x - metric.median) / max(metric.mad, floor)
    }

    private func metricBaseline(values: [Double], fallbackMedian: Double) -> MetricBaseline {
        guard values.count >= thresholds.baselineMinSamples, let median = Self.median(values) else {
            return MetricBaseline(median: fallbackMedian, mad: 0, count: values.count)
        }
        let deviations = values.map { abs($0 - median) }
        let mad = Self.median(deviations) ?? 0
        return MetricBaseline(median: median, mad: mad, count: values.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
