import Foundation

/// Test clock whose time only moves when a test says so. Lock-based because
/// `Clock.now()` must be synchronous, which an actor cannot provide.
final class ManualClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private let lock = NSLock()
    private var _now: Instant
    private var waiters: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []

    init(from start: Instant = ContinuousClock().now) {
        _now = start
    }

    var now: Instant {
        lock.withLockUnsafe { _now }
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by amount: Duration) {
        lock.lock()
        _now += amount
        let due = waiters.filter { $0.deadline <= _now }
        waiters.removeAll { $0.deadline <= _now }
        lock.unlock()
        for waiter in due { waiter.continuation.resume(returning: ()) }
    }

    func advanceMinutes(_ minutes: Double) {
        // `Duration.minutes` is unavailable on this toolchain's SDK floor;
        // milliseconds is the smallest factory that always exists.
        advance(by: Swift.Duration.milliseconds(minutes * 60_000))
    }

    func sleep(until deadline: Instant, tolerance: Instant.Duration?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if deadline <= _now {
                lock.unlock()
                continuation.resume(returning: ())
                return
            }
            waiters.append((deadline, continuation))
            lock.unlock()
        }
    }
}

private extension NSLock {
    /// `withLock` arrived in newer SDKs than our macOS 14 floor targets.
    func withLockUnsafe<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Polls an async condition until it holds or the deadline passes.
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(3),
    pollingEvery interval: Duration = .milliseconds(2),
    condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    var done = await condition()
    while !done {
        if ContinuousClock.now >= deadline {
            throw TimeoutError(description)
        }
        try await ContinuousClock().sleep(for: interval)
        done = await condition()
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "waitUntil timed out: \(description)" }
}
