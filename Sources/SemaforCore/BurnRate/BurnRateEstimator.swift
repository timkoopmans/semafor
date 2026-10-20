import Foundation

/// Pure projections over limit-window usage samples (spec §8.3): least-squares
/// drain slope, time-to-exhaustion with a half-slope band, and the
/// ahead-of-pace check that feeds the BUSY verdict.
public enum BurnRateEstimator {
    public struct Projection: Equatable, Sendable {
        public let slopePercentPerHour: Double
        public let eta: Date?
        public let band: Duration?
        public let headline: String
    }

    public static func project(
        samples: [(at: Date, usedPercent: Double)],
        now: Date,
        minSpan: Duration = .seconds(2 * 3600),
        flatEpsilon: Double = 0.01
    ) -> Projection? {
        // Review Focus (time anomalies): future-dated samples are dropped and
        // input order is normalized before fitting.
        let valid = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        guard valid.count >= 2 else { return nil }
        let span = valid[valid.count - 1].at.timeIntervalSince(valid[0].at)
        guard span >= Double(minSpan.components.seconds) else { return nil }

        let xs = valid.map { $0.at.timeIntervalSince(now) }
        let ys = valid.map(\.usedPercent)
        let slopePerHour = slope(xs: xs, ys: ys) * 3600
        let current = ys[ys.count - 1]

        if abs(slopePerHour) < flatEpsilon {
            return Projection(
                slopePercentPerHour: slopePerHour, eta: nil, band: nil,
                headline: "no measurable drain in the last 2h")
        }
        guard slopePerHour > 0 else {
            // Usage going backwards (window reset mid-series, clock skew):
            // no sensible ETA exists; report as no measurable drain.
            return Projection(
                slopePercentPerHour: slopePerHour, eta: nil, band: nil,
                headline: "no measurable drain in the last 2h")
        }

        let remaining = max(0, 100 - current)
        let eta = now.addingTimeInterval(remaining / slopePerHour * 3600)
        let band = bandSeconds(
            xs: xs, ys: ys, current: current, slopePerHour: slopePerHour, now: now)

        return Projection(
            slopePercentPerHour: slopePerHour,
            eta: eta,
            band: band,
            headline: "at this pace, gone ~\(render(eta)) (±\(render(band)))")
    }

    public enum PaceStatus: Equatable, Sendable {
        case ok
        case aheadOfPace(deltaPoints: Double)
        case notEnoughData
    }

    public static func pace(
        usedPercent: Double?,
        windowSeconds: Int?,
        resetsAt: Date?,
        now: Date,
        threshold: Double = 15
    ) -> PaceStatus {
        guard let usedPercent, let windowSeconds, let resetsAt, windowSeconds > 0 else {
            return .notEnoughData
        }
        let start = resetsAt.addingTimeInterval(-Double(windowSeconds))
        let elapsed = now.timeIntervalSince(start) / Double(windowSeconds) * 100
        let elapsedClamped = min(max(elapsed, 0), 100)
        let delta = usedPercent - elapsedClamped
        return delta > threshold ? .aheadOfPace(deltaPoints: delta) : .ok
    }

    // MARK: - Fitting

    private static func slope(xs: [Double], ys: [Double]) -> Double {
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for index in xs.indices {
            covariance += (xs[index] - meanX) * (ys[index] - meanY)
            variance += (xs[index] - meanX) * (xs[index] - meanX)
        }
        return variance == 0 ? 0 : covariance / variance
    }

    /// Band = |eta(firstHalfSlope) − eta(secondHalfSlope)|, clamped to
    /// 30 min…30 days (spec §8.3). Halves too small to fit fall back to the
    /// full-range slope, yielding the 30-minute floor.
    private static func bandSeconds(
        xs: [Double], ys: [Double], current: Double, slopePerHour: Double, now: Date
    ) -> Duration {
        let floor = 1800.0
        let ceiling = 30 * 24 * 3600.0
        let remaining = max(0, 100 - current)
        let tinySlope = 0.0001  // %/h guard to avoid divide-by-tiny

        func etaSeconds(for perHour: Double) -> Double {
            guard perHour > tinySlope else { return ceiling }
            return min(remaining / perHour * 3600.0, ceiling)
        }

        let mid = (xs.first! + xs.last!) / 2
        let firstHalf = xs.indices.filter { xs[$0] <= mid }
        let secondHalf = xs.indices.filter { xs[$0] > mid }

        guard firstHalf.count >= 2, secondHalf.count >= 2 else {
            return Duration.seconds(floor)
        }
        let slope1 = slope(xs: firstHalf.map { xs[$0] }, ys: firstHalf.map { ys[$0] }) * 3600
        let slope2 = slope(xs: secondHalf.map { xs[$0] }, ys: secondHalf.map { ys[$0] }) * 3600
        let raw = abs(etaSeconds(for: slope1) - etaSeconds(for: slope2))
        return Duration.seconds(min(max(raw, floor), ceiling))
    }

    // MARK: - Rendering

    private static func render(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }

    private static func render(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        if seconds < 3600 {
            return "\(max(1, Int((Double(seconds) + 59) / 60)))m"
        }
        return "\(max(1, Int((Double(seconds) + 1800) / 3600)))h"
    }
}
