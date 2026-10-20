import Foundation
import Testing
@testable import SemaforCore

/// Learned median/MAD baselines segmented by provider × model × weekend ×
/// 6-hour bucket, with MAD-floored z-scores (spec §8.1).
struct BaselineEngineTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func makeThresholds(minSamples: Int = 20) -> Thresholds {
        Thresholds(
            zWarn: 3, zCrawl: 6, consecutiveN: 3, busyPercent: 80, limitedPercent: 98,
            paceDeltaPoints: 15, baselineMinSamples: minSamples,
            baselineDefaultTTFT: 8, baselineDefaultTokPerSec: 20)
    }

    private func engine(minSamples: Int = 20) -> BaselineEngine {
        BaselineEngine(thresholds: makeThresholds(minSamples: minSamples), calendar: calendar)
    }

    /// Mon 2026-10-19 / Sat 2026-10-17 baselines; `hour` in UTC.
    private func date(weekend: Bool, hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 10
        components.day = weekend ? 17 : 19
        components.hour = hour; components.minute = minute; components.second = second
        return calendar.date(from: components)!
    }

    private func sample(
        at timestamp: Date,
        model: String = "claude-opus-5-5",
        provider: ProviderID = .claude,
        ttft: Double? = 2.0,
        tokPerSec: Double? = 80,
        outcome: ProbeOutcome = .ok
    ) -> ProbeSample {
        ProbeSample(
            provider: provider, model: model, sessionKey: "f#\(UUID().uuidString)",
            ttft: ttft, duration: 3, tokensPerSecond: tokPerSec,
            outcome: outcome, timestamp: timestamp)
    }

    @Test func keySegmentsByBucketAndWeekend() {
        let subject = engine()
        let before = subject.key(at: date(weekend: false, hour: 5, minute: 59, second: 59),
                                 provider: .claude, model: "m")
        let after = subject.key(at: date(weekend: false, hour: 6), provider: .claude, model: "m")
        #expect(before.bucket == 0 && after.bucket == 1)
        #expect(before != after)

        let weekday = subject.key(at: date(weekend: false, hour: 10), provider: .claude, model: "m")
        let saturday = subject.key(at: date(weekend: true, hour: 10), provider: .claude, model: "m")
        #expect(!weekday.weekend && saturday.weekend)
        #expect(weekday != saturday)

        let otherModel = subject.key(at: date(weekend: false, hour: 10), provider: .claude, model: "other")
        #expect(weekday != otherModel)
    }

    @Test func learnedAtThresholdWithMedianAndMADFromData() {
        let subject = engine()
        let at = date(weekend: false, hour: 10)
        let key = subject.key(at: at, provider: .claude, model: "claude-opus-5-5")

        // 20 ttfts: 10×1.5, 10×2.5 ⇒ median 2.0, MAD 0.5.
        var samples: [ProbeSample] = []
        for i in 0..<10 { samples.append(sample(at: at.addingTimeInterval(Double(i) * 60), ttft: 1.5)) }
        for i in 0..<10 { samples.append(sample(at: at.addingTimeInterval(700 + Double(i) * 60), ttft: 2.5)) }

        let set = subject.baseline(for: key, samples: samples, now: at.addingTimeInterval(3600))
        #expect(set.learned)
        #expect(set.ttft.median == 2.0)
        #expect(set.ttft.mad == 0.5)
        #expect(set.ttft.count == 20)
        #expect(set.tokPerSec.median == 80)  // uniform values
    }

    @Test func belowThresholdUsesAbsoluteDefaultsPerMetric() {
        let subject = engine()
        let at = date(weekend: false, hour: 10)
        let key = subject.key(at: at, provider: .claude, model: "claude-opus-5-5")
        let nineteen = (0..<19).map { sample(at: at.addingTimeInterval(Double($0) * 60)) }

        let set = subject.baseline(for: key, samples: nineteen, now: at.addingTimeInterval(3600))
        #expect(!set.learned)
        #expect(set.ttft.median == 8)  // baselineDefaultTTFT
        #expect(set.ttft.mad == 0)
        #expect(set.ttft.count == 19)  // count stays real
        #expect(set.tokPerSec.median == 20)  // baselineDefaultTokPerSec
    }

    @Test func unusableSamplesExcludedFromMedians() {
        let subject = engine()
        let at = date(weekend: false, hour: 10)
        let key = subject.key(at: at, provider: .claude, model: "claude-opus-5-5")
        let future = date(weekend: false, hour: 11, minute: 30)

        var samples = (0..<25).map { sample(at: at.addingTimeInterval(Double($0) * 60), ttft: 2.0) }
        samples.append(sample(at: future, ttft: 500))  // future ⇒ excluded
        samples.append(sample(at: at, ttft: 900, outcome: .timeout))  // non-ok ⇒ excluded
        samples.append(sample(at: at.addingTimeInterval(1), model: "claude-sonnet-5-5"))  // other model

        let set = subject.baseline(for: key, samples: samples, now: at.addingTimeInterval(3600))
        #expect(set.learned)
        #expect(set.ttft.count == 25)
        #expect(set.ttft.median == 2.0)
    }

    @Test func otherModelBaselinesStaySeparate() {
        let subject = engine()
        let at = date(weekend: false, hour: 10)
        let opusKey = subject.key(at: at, provider: .claude, model: "claude-opus-5-5")
        let samples = (0..<10).map { sample(at: at.addingTimeInterval(Double($0) * 60), ttft: 2.0) }
            + (0..<20).map { sample(at: at.addingTimeInterval(Double($0) * 60),
                                    model: "claude-sonnet-5-5", ttft: 0.4) }
        // Opus has only 10 in-bucket samples ⇒ defaults, not sonnet's 0.4.
        let opus = subject.baseline(for: opusKey, samples: samples, now: at.addingTimeInterval(3600))
        #expect(opus.ttft.median == 8)
    }

    @Test func singleOutlierDoesNotInflateNormals() {
        let subject = engine()
        let at = date(weekend: false, hour: 10)
        let key = subject.key(at: at, provider: .claude, model: "claude-opus-5-5")
        let fast = (0..<24).map { sample(at: at.addingTimeInterval(Double($0) * 60), ttft: 2.0) }
        let outlier = sample(at: at.addingTimeInterval(2400), ttft: 100)

        let set = subject.baseline(for: key, samples: fast + [outlier], now: at.addingTimeInterval(3600))
        #expect(set.ttft.median == 2.0)
        #expect(set.ttft.mad == 0)  // all-but-one identical ⇒ spread collapses
        // Normal probe against MAD-floored baseline stays quiet.
        let z = subject.z(2.1, metric: set.ttft, floor: 0.25)
        #expect(z < 3)
    }

    @Test func zUsesFloorWhenMadCollapses() {
        let subject = engine()
        let metric = MetricBaseline(median: 2.0, mad: 0, count: 30)
        #expect(subject.z(3.0, metric: metric, floor: 0.25) == 4.0)
        #expect(subject.z(2.0, metric: metric, floor: 0.25) == 0)
        let wide = MetricBaseline(median: 2.0, mad: 1.0, count: 30)
        #expect(subject.z(4.5, metric: wide, floor: 0.25) == 2.5)
    }

    @Test func sparseBucketRelaxesToNeighbourBucketsBeforeDefaults() {
        // Dogfood bug: tiles queried the CURRENT 6-hour bucket over a 24 h
        // pool; a quiet evening printed the absolute defaults as "usual".
        // A bucket-poor segment must borrow other buckets' history instead.
        let subject = engine()
        let noon = date(weekend: false, hour: 11)
        let key = subject.key(at: noon, provider: .claude, model: "claude-opus-5-5")
        // Nothing at all in bucket 1 (06–12 h): all history is pre-dawn.
        let samples = (0..<25).map {
            sample(at: date(weekend: false, hour: $0 % 2 == 0 ? 1 : 4, minute: $0),
                   ttft: 3.0, tokPerSec: 60)
        }
        let set = subject.baseline(for: key, samples: samples, now: noon.addingTimeInterval(3600))
        #expect(set.learned)
        #expect(set.ttft.median == 3.0)      // not the 8 default
        #expect(set.tokPerSec.median == 60)  // not the 20 default
    }

    @Test func weekendSplitRelaxesWhenThatSideHasNoHistory() {
        // Work-only tools queried on a Sunday: weekday history still learns.
        let subject = engine()
        let sunday = date(weekend: true, hour: 10)
        let key = subject.key(at: sunday, provider: .claude, model: "claude-opus-5-5")
        let weekdays = (0..<25).map {
            sample(at: date(weekend: false, hour: 10, minute: $0), ttft: 1.5, tokPerSec: 90)
        }
        // Query key is the weekend segment; the clock sits after the history.
        let set = subject.baseline(for: key, samples: weekdays, now: date(weekend: false, hour: 19))
        #expect(set.learned)
        #expect(set.ttft.median == 1.5)
        #expect(set.tokPerSec.median == 90)
    }

    @Test func relaxationNeverCrossesModelOrProvider() {
        // 40 samples of ANOTHER model in the same bucket: opus must still
        // fall back to the absolute default, not borrow sonnet's history.
        let subject = engine()
        let at = date(weekend: false, hour: 10)
        let key = subject.key(at: at, provider: .claude, model: "claude-opus-5-5")
        let sonnet = (0..<40).map {
            sample(at: at.addingTimeInterval(Double($0) * 60),
                   model: "claude-sonnet-5-5", ttft: 0.4, tokPerSec: 220)
        }
        let set = subject.baseline(for: key, samples: sonnet, now: at.addingTimeInterval(3600))
        #expect(!set.learned)
        #expect(set.ttft.median == 8)
        #expect(set.tokPerSec.median == 20)
    }

    @Test func missingMetricValuesDoNotCount() {
        let subject = engine()
        let at = date(weekend: false, hour: 10)
        let key = subject.key(at: at, provider: .claude, model: "claude-opus-5-5")
        // All ttfts present, all tok/s nil (tiny calls) ⇒ tokPerSec under threshold, ttft learned.
        let samples = (0..<21).map { sample(at: at.addingTimeInterval(Double($0) * 60), tokPerSec: nil) }
        let set = subject.baseline(for: key, samples: samples, now: at.addingTimeInterval(3600))
        #expect(!set.learned)  // both required
        #expect(set.ttft.count == 21 && set.ttft.median == 2.0)
        #expect(set.tokPerSec.count == 0 && set.tokPerSec.median == 20)
    }
}
