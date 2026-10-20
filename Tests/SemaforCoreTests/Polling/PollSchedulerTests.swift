import Foundation
import Testing

@testable import SemaforCore

private actor ScriptedProvider: Provider {
    enum Step {
        case success([UsageWindow])
        case failure(ProviderError)
        case gate  // hang until releaseGate(), then apply fallback
    }

    let id: ProviderID
    nonisolated let pollingEnabled: Bool
    private var steps: [Step]
    private let fallback: Step
    private var gateContinuation: CheckedContinuation<Void, Never>?

    private(set) var callCount = 0

    init(
        id: ProviderID,
        steps: [Step],
        fallback: Step = .failure(.network),
        pollingEnabled: Bool = true
    ) {
        self.id = id
        self.steps = steps
        self.fallback = fallback
        self.pollingEnabled = pollingEnabled
    }

    func fetchLimits() async throws -> [UsageWindow] {
        callCount += 1
        let step = steps.isEmpty ? fallback : steps.removeFirst()
        switch step {
        case .failure(let error):
            throw error
        case .success(let windows):
            return windows
        case .gate:
            await withCheckedContinuation { gateContinuation = $0 }
            gateContinuation = nil
            switch fallback {
            case .success(let windows): return windows
            case .failure(let error): throw error
            case .gate: return []
            }
        }
    }

    func releaseGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    nonisolated var sessionLogPaths: [URL] { [] }

    func statusPage() async throws -> StatusPageState { .unknown }
}

private actor SpyWriter: LimitsWriting {
    private(set) var records: [StoreRecord] = []

    func append(_ record: StoreRecord) async throws {
        records.append(record)
    }
}

private func window(_ name: WindowName, _ percent: Double) -> UsageWindow {
    UsageWindow(name: name, usedPercent: percent, windowSeconds: 18_000, resetsAt: nil, fetchedAt: Date())
}

private func makeSettings(intervalMinutes: Int = 5) -> AppSettings {
    let settings = AppSettings(defaults: UserDefaults(suiteName: "PollSchedulerTests.\(UUID().uuidString)")!)
    settings.pollIntervalMinutes = intervalMinutes
    return settings
}

@Suite("PollScheduler")
struct PollSchedulerTests {
    @Test func startPollsImmediatelyThenOnInterval() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(id: .claude, steps: [], fallback: .success([window(.fiveHour, 10)]))
        let scheduler = PollScheduler(providers: [provider], writer: nil, settings: makeSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("first poll lands") { await provider.callCount == 1 }

        await scheduler.start()  // idempotent — no extra immediate poll
        clock.advanceMinutes(3)  // below jittered interval
        await Task.yield()
        try? await ContinuousClock().sleep(for: .milliseconds(20))
        #expect(await provider.callCount == 1)

        clock.advanceMinutes(3)  // total 6 min > jittered 5 ± 10%
        try await waitUntil("second poll lands") { await provider.callCount == 2 }
    }

    @Test func failureKeepsPreviousWindowsAndSetsError() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(
            id: .claude,
            steps: [.success([window(.fiveHour, 10)]), .failure(.network)],
            fallback: .failure(.network))
        let scheduler = PollScheduler(providers: [provider], writer: nil, settings: makeSettings(), clock: clock)

        await scheduler.start()
        // Real signal required: an empty snapshot dict would make `?.lastError == nil` vacuously true.
        try await waitUntil("first success") {
            await scheduler.snapshots()[.claude]?.windows.count == 1
        }

        clock.advanceMinutes(6)
        try await waitUntil("failure recorded") {
            await scheduler.snapshots()[.claude]?.lastError == ProviderError.network
        }
        let snapshot = try #require(await scheduler.snapshots()[.claude])
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.name == .fiveHour)
        #expect(snapshot.windows.first?.usedPercent == 10)
    }

    @Test func refreshWhileInFlightCoalesces() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(
            id: .codex,
            steps: [.gate, .gate],
            fallback: .success([window(.primary, 20)]))
        let scheduler = PollScheduler(providers: [provider], writer: nil, settings: makeSettings(), clock: clock)

        let first = Task { await scheduler.refresh(.codex) }
        try await waitUntil("first poll in flight") { await provider.callCount == 1 }

        let second = Task { await scheduler.refresh(.codex) }
        let third = Task { await scheduler.refresh(.codex) }
        try? await ContinuousClock().sleep(for: .milliseconds(30))
        #expect(await provider.callCount == 1)  // coalesced into one pending, no extra fetch

        await provider.releaseGate()
        try await waitUntil("pending poll runs") { await provider.callCount == 2 }
        await provider.releaseGate()
        await first.value
        await second.value
        await third.value
        #expect(await provider.callCount == 2)  // two refreshes while in flight → one extra poll
    }

    @Test func pausedStopsTicks() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(id: .claude, steps: [], fallback: .success([window(.fiveHour, 10)]))
        let scheduler = PollScheduler(providers: [provider], writer: nil, settings: makeSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("first poll") { await provider.callCount == 1 }

        await scheduler.setPaused(true)
        clock.advanceMinutes(12)
        try? await ContinuousClock().sleep(for: .milliseconds(30))
        #expect(await provider.callCount == 1)

        await scheduler.setPaused(false)
        clock.advanceMinutes(6)
        try await waitUntil("resumed tick polls") { await provider.callCount == 2 }
    }

    @Test func successfulPollWritesToStore() async throws {
        let clock = ManualClock()
        let writer = SpyWriter()
        let provider = ScriptedProvider(id: .claude, steps: [], fallback: .success([window(.fiveHour, 42)]))
        let scheduler = PollScheduler(providers: [provider], writer: writer, settings: makeSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("record written") {
            await writer.records.contains { if case .limits = $0 { return true } else { return false } }
        }
        let record = try #require(await writer.records.first { if case .limits = $0 { return true } else { return false } })
        guard case .limits(let id, let windows, let fetchedAt) = record else {
            Issue.record("expected a limits record")
            return
        }
        #expect(id == .claude)
        #expect(windows.count == 1)
        #expect(windows.first?.usedPercent == 42)
        let snapshotFetchedAt = await scheduler.snapshots()[.claude]?.fetchedAt
        #expect(fetchedAt == snapshotFetchedAt)
    }

    @Test func staleAfterThreeIntervalsWithoutSuccess() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(
            id: .claude,
            steps: [.success([window(.fiveHour, 10)])],
            fallback: .failure(.network))
        let scheduler = PollScheduler(providers: [provider], writer: nil, settings: makeSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("first success") { await scheduler.snapshots()[.claude] != nil }
        let fetchedAt = try #require(await scheduler.snapshots()[.claude]).fetchedAt

        #expect(!(await scheduler.isStale(.claude, now: fetchedAt.addingTimeInterval(60))))
        #expect(await scheduler.isStale(.claude, now: fetchedAt.addingTimeInterval(16 * 60)))
    }

    @Test func lateSubscriberReceivesLatestSnapshots() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(id: .claude, steps: [], fallback: .success([window(.fiveHour, 10)]))
        let scheduler = PollScheduler(providers: [provider], writer: nil, settings: makeSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("first poll") { await scheduler.snapshots()[.claude] != nil }

        let stream = scheduler.updates()
        let latest = await stream.first()
        #expect(latest?[.claude]?.windows.count == 1)
    }

    @Test func disabledStopsSchedulerPolling() async throws {
        let clock = ManualClock()
        let hal = ScriptedProvider(id: .hal, steps: [], fallback: .success([]), pollingEnabled: false)
        let claude = ScriptedProvider(id: .claude, steps: [], fallback: .success([window(.fiveHour, 10)]))
        let scheduler = PollScheduler(providers: [hal, claude], writer: nil, settings: makeSettings(), clock: clock)

        await scheduler.start()
        try await waitUntil("first claude poll") { await claude.callCount == 1 }
        // Advance in two hops with a settle gap so a runLoop that registers
        // its clock sleep after the first hop still finds its deadline due
        // after the second (same double-advance shape as the tick tests).
        clock.advanceMinutes(6)  // well past the jittered 5-min interval
        try? await ContinuousClock().sleep(for: .milliseconds(30))
        clock.advanceMinutes(6)
        try await waitUntil("claude still polling") { await claude.callCount == 2 }
        #expect(await hal.callCount == 0)  // disabled provider skipped on ticks

        await scheduler.refresh(.hal)  // manual refresh gated too
        #expect(await hal.callCount == 0)
    }
}

private extension AsyncStream {
    func first() async -> Element? {
        for await element in self { return element }
        return nil
    }
}
