import Foundation
import Testing

@testable import SemaforCore

@Suite("BurnRateEstimator.project")
struct BurnRateProjectTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func hourly(_ percents: [Double], endingAt end: Date) -> [(at: Date, usedPercent: Double)] {
        percents.enumerated().map { index, percent in
            (end.addingTimeInterval(-Double(percents.count - 1 - index) * 3600), percent)
        }
    }

    @Test func steadyDrainProjectsETA() throws {
        let samples = hourly([10, 15, 20, 25, 30], endingAt: now)  // exactly 5 %/h
        let projection = try #require(BurnRateEstimator.project(samples: samples, now: now))
        #expect(abs(projection.slopePercentPerHour - 5.0) < 0.01)
        let expectedETA = now.addingTimeInterval(14 * 3600)  // (100-30)/5 = 14 h
        let drift = abs(projection.eta!.timeIntervalSince(expectedETA))
        #expect(drift < 600)  // ±10 min
        #expect(projection.headline.hasPrefix("at this pace, gone ~"))
        #expect(projection.headline.wholeMatch(of: /at this pace, gone ~\w{3} \d{2}:\d{2} \(±\d+[hm]\)/) != nil)
    }

    @Test func flatSamplesYieldNoDrainHeadline() {
        let samples = hourly([30.0, 30.004, 30.008], endingAt: now)  // 0.004 %/h < flatEpsilon
        let projection = BurnRateEstimator.project(samples: samples, now: now)!
        #expect(projection.eta == nil)
        #expect(projection.headline == "no measurable drain in the last 2h")
    }

    @Test func underTwoHourSpanYieldsNil() {
        let samples = [(now.addingTimeInterval(-5400), 40.0), (now.addingTimeInterval(-1800), 45.0)]
        #expect(BurnRateEstimator.project(samples: samples, now: now) == nil)
    }

    @Test func singleSampleYieldsNil() {
        #expect(BurnRateEstimator.project(samples: [(now, 40.0)], now: now) == nil)
    }

    @Test func futureSamplesFilteredAndOrderingTolerated() {
        var samples = hourly([10, 15, 20, 25, 30], endingAt: now)
        samples.append((now.addingTimeInterval(3600), 99))   // future: dropped
        samples.shuffle()
        let projection = BurnRateEstimator.project(samples: samples, now: now)!
        #expect(abs(projection.slopePercentPerHour - 5.0) < 0.01)
    }

    @Test func sparseVariygingSamplesProduceFiniteBandAtLeastHalfAnHour() throws {
        let samples: [(at: Date, usedPercent: Double)] = [
            (now.addingTimeInterval(-10 * 3600), 12),
            (now.addingTimeInterval(-7 * 3600), 26),
            (now.addingTimeInterval(-5 * 3600), 27),
            (now.addingTimeInterval(-2 * 3600), 44),
        ]
        let projection = try #require(BurnRateEstimator.project(samples: samples, now: now))
        #expect(projection.slopePercentPerHour > 0)
        #expect(projection.band! >= Duration.seconds(1800))
        #expect(projection.band! <= Duration.seconds(30 * 24 * 3600))
    }
}

@Suite("BurnRateEstimator.pace")
struct PaceTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let week = 604_800.0

    @Test func usedThirtyPointsAheadOfElapsedPace() {
        let resetsAt = now.addingTimeInterval(0.8 * week)  // elapsed = 20 %
        let status = BurnRateEstimator.pace(
            usedPercent: 50, windowSeconds: 604_800, resetsAt: resetsAt, now: now)
        #expect(status == .aheadOfPace(deltaPoints: 30))
    }

    @Test func withinThresholdIsOK() {
        let resetsAt = now.addingTimeInterval(0.55 * week)  // elapsed = 45 %
        let status = BurnRateEstimator.pace(
            usedPercent: 50, windowSeconds: 604_800, resetsAt: resetsAt, now: now)
        #expect(status == .ok)
    }

    @Test func nilInputsYieldNotEnoughData() {
        #expect(BurnRateEstimator.pace(usedPercent: nil, windowSeconds: 604_800, resetsAt: now, now: now) == .notEnoughData)
        #expect(BurnRateEstimator.pace(usedPercent: 50, windowSeconds: nil, resetsAt: now, now: now) == .notEnoughData)
        #expect(BurnRateEstimator.pace(usedPercent: 50, windowSeconds: 604_800, resetsAt: nil, now: now) == .notEnoughData)
    }
}
