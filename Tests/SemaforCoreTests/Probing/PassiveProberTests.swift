import Foundation
import Testing
@testable import SemaforCore

/// Scan loop, backfill, dedupe-free offset resume, control gate, and update
/// stream of the passive prober (spec §7). Log files are seeded in temp
/// dirs; all logical time flows through an injected clock.
struct PassiveProberTests {
    private final class TimeBox: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private let now = Date(timeIntervalSince1970: 1_792_470_000) // 2026-10-20T11:00:00Z

    private struct LogProvider: Provider {
        let id: ProviderID
        let logDir: URL
        func fetchLimits() async throws -> [UsageWindow] { throw ProviderError.network }
        func statusPage() async throws -> StatusPageState { .unknown }
        nonisolated var sessionLogPaths: [URL] { [logDir] }
    }

    private actor SpyWriter: LimitsWriting {
        private(set) var records: [StoreRecord] = []
        func append(_ record: StoreRecord) async throws { records.append(record) }
        func reset() { records = [] }
    }

    private actor SpyControl: ControlProbing {
        private(set) var calls: [ProviderID] = []
        func measure(_ id: ProviderID) async -> ControlSample {
            calls.append(id)
            return ControlSample(provider: id, latency: 0.5, timestamp: Date())
        }
    }

    // MARK: - Helpers

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Two-call Claude session: one complete `api-request`/`assistant` pair
    /// with `output_tokens: 80` over 2 s (40 tok/s), starting at `start`.
    private func claudePair(id: String, start: Date, model: String = "claude-opus-5-5") -> String {
        let t0 = iso(start), t1 = iso(start.addingTimeInterval(1)), t2 = iso(start.addingTimeInterval(2))
        return """
        {"type":"api-request","id":"\(id)","timestamp":"\(t0)","querySource":"repl_main_thread","params":{"model":"\(model)"}}
        {"type":"assistant","requestRef":"\(id)","requestedModel":"\(model)","timestamp":"\(t1)","message":{"model":"\(model)","usage":{"output_tokens":40}}}
        {"type":"assistant","requestRef":"\(id)","requestedModel":"\(model)","timestamp":"\(t2)","message":{"model":"\(model)","usage":{"output_tokens":80}}}

        """
    }

    private struct Harness {
        let prober: PassiveProber
        let tailer: SessionLogTailer
        let writer: SpyWriter
        let control: SpyControl
        let logDir: URL
        let time: TimeBox
        let stateURL: URL
    }

    private func makeHarness(
        seed: [String: String] = [:],
        controlEnabled: Bool = true,
        nowOffset: TimeInterval = 60  // dateNow = last sample + 60 s
    ) throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semafor-prober-\(UUID().uuidString)")
        let logDir = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        for (name, contents) in seed {
            try Data(contents.utf8).write(to: logDir.appendingPathComponent(name))
        }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PassiveProberTests.\(UUID().uuidString)")!)
        settings.controlProbeEnabled = controlEnabled

        let time = TimeBox(now.addingTimeInterval(nowOffset))
        let stateURL = root.appendingPathComponent("tail.json")
        let tailer = SessionLogTailer(stateURL: stateURL)
        let provider = LogProvider(id: .claude, logDir: logDir)
        let writer = SpyWriter()
        let control = SpyControl()
        let prober = PassiveProber(
            providers: [provider],
            tailer: tailer,
            extractors: [.claude: ClaudeLogExtractor(quietPeriod: 2)],
            control: control,
            writer: writer,
            settings: settings,
            dateNow: { time.date },
            clock: ManualClock())
        return Harness(prober: prober, tailer: tailer, writer: writer, control: control,
                       logDir: logDir, time: time, stateURL: stateURL)
    }

    private func probeRecords(_ records: [StoreRecord]) -> [ProbeSample] {
        records.compactMap { if case .probe(let s) = $0 { s } else { nil } }
    }

    // MARK: - Scan + publish

    @Test func scanNowStoresAndPublishesSamples() async throws {
        let h = try makeHarness(seed: ["s.jsonl": claudePair(id: "r1", start: now)])
        let stream = h.prober.updates()
        await h.prober.scanNow()

        let records = await h.writer.records
        let samples = probeRecords(records)
        #expect(samples.count == 1)
        #expect(samples[0].tokensPerSecond == 40)
        #expect(samples[0].sessionKey == "s.jsonl#r1")

        let latest = await h.prober.latestProbes()
        #expect(latest.map(\.sessionKey) == ["s.jsonl#r1"])

        let snapshot = try #require(await stream.first())
        #expect(snapshot.map(\.sessionKey) == ["s.jsonl#r1"])
    }

    @Test func secondScanWithoutGrowthStoresNothing() async throws {
        let h = try makeHarness(seed: ["s.jsonl": claudePair(id: "r1", start: now)])
        await h.prober.scanNow()
        await h.prober.scanNow()
        #expect(probeRecords(await h.writer.records).count == 1)
    }

    @Test func appendedLineProducesNewSample() async throws {
        let h = try makeHarness(seed: ["s.jsonl": claudePair(id: "r1", start: now)])
        await h.prober.scanNow()

        let file = h.logDir.appendingPathComponent("s.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(claudePair(id: "r2", start: now).utf8))
        try handle.close()

        await h.prober.scanNow()
        let keys = probeRecords(await h.writer.records).map(\.sessionKey).sorted()
        #expect(keys == ["s.jsonl#r1", "s.jsonl#r2"])
    }

    // MARK: - Control gate

    @Test func noSamplesMeansNoControlCalls() async throws {
        let h = try makeHarness(seed: ["s.jsonl": #"{"type":"unrelated"}""# + "\n"])
        await h.prober.scanNow()
        #expect(await h.control.calls.isEmpty)
    }

    @Test func freshSampleTriggersControlOncePerInterval() async throws {
        let h = try makeHarness(seed: ["s.jsonl": claudePair(id: "r1", start: now)])
        await h.prober.scanNow()  // sample at 11:00, now = 11:01 ⇒ fresh
        #expect(await h.control.calls == [.claude])

        await h.prober.scanNow()  // still inside the 5-min control window
        #expect(await h.control.calls.count == 1)

        h.time.date = h.time.date.addingTimeInterval(2 * 60)  // sample 8 min old
        await h.prober.scanNow()  // inside the interval gate ⇒ still no re-fire
        #expect(await h.control.calls.count == 1)
    }

    @Test func controlRefiresAfterIntervalWithFreshSample() async throws {
        // Keep the newest sample young by appending a new call each pass.
        let h = try makeHarness(seed: ["s.jsonl": claudePair(id: "r1", start: now)])
        await h.prober.scanNow()
        #expect(await h.control.calls.count == 1)

        h.time.date = h.time.date.addingTimeInterval(6 * 60)  // past the 5-min gate
        let file = h.logDir.appendingPathComponent("s.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            claudePair(id: "r2", start: h.time.date.addingTimeInterval(-30)).utf8))
        try handle.close()
        await h.prober.scanNow()
        #expect(await h.control.calls.count == 2)
    }

    @Test func disabledControlNeverFires() async throws {
        let h = try makeHarness(
            seed: ["s.jsonl": claudePair(id: "r1", start: now)], controlEnabled: false)
        await h.prober.scanNow()
        await h.prober.scanNow()
        #expect(await h.control.calls.isEmpty)
    }

    // MARK: - Measured count

    @Test func measuredCountTodayCountsOkOnly() async throws {
        // One ok call plus a superseded stall (timeout) in the same file.
        let stalled: String =
            """
            {"type":"api-request","id":"stall","timestamp":"\(iso(now))","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}
            {"type":"api-request","id":"next","timestamp":"\(iso(now.addingTimeInterval(60)))","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}
            {"type":"assistant","requestRef":"next","requestedModel":"claude-opus-5-5","timestamp":"\(iso(now.addingTimeInterval(61)))","message":{"model":"claude-opus-5-5","usage":{"output_tokens":50}}}
            {"type":"assistant","requestRef":"next","requestedModel":"claude-opus-5-5","timestamp":"\(iso(now.addingTimeInterval(63)))","message":{"model":"claude-opus-5-5","usage":{"output_tokens":100}}}

            """
        let h = try makeHarness(seed: ["s.jsonl": claudePair(id: "ok", start: now) + stalled])
        await h.prober.scanNow()
        let samples = probeRecords(await h.writer.records)
        #expect(samples.count == 2)
        #expect(samples.contains { $0.outcome == .timeout })
        #expect(await h.prober.measuredCountToday(provider: .claude) == 1)
    }

    // MARK: - Backfill

    @Test func scanNowPersistsTailerState() async throws {
        // Regression: offsets must reach disk, or every launch re-reads the
        // whole log tree and re-appends the day's samples as duplicates.
        let h = try makeHarness(seed: ["s.jsonl": claudePair(id: "r1", start: now)])
        await h.prober.scanNow()
        let data = try #require(try? Data(contentsOf: h.stateURL))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("s.jsonl"))

        // Fresh instance on the same state must not re-read the file.
        await h.tailer.loadState()
        await h.prober.scanNow()
        #expect(probeRecords(await h.writer.records).count == 1)
    }

    @Test func backfillSeedsOnceWithoutDuplicates() async throws {
        // "Yesterday" file relative to dateNow; scan loop runs on ManualClock
        // so only the initial pass executes.
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let h = try makeHarness(
            seed: ["yesterday.jsonl": claudePair(id: "old", start: yesterday)],
            nowOffset: 60)
        await h.prober.start()
        try await waitUntil("backfill stored") { await h.writer.records.count == 1 }

        await h.prober.scanNow()  // same bytes, offsets already advanced
        #expect(await h.writer.records.count == 1)

        await h.prober.start()  // second start is a no-op
        try await Task.sleep(for: .milliseconds(30))
        #expect(await h.writer.records.count == 1)
    }

    @Test func backfillIgnoresSamplesOutsideWindow() async throws {
        // 30 days old with backfillDays = 7 (default).
        let old = now.addingTimeInterval(-30 * 24 * 3600)
        let h = try makeHarness(seed: ["ancient.jsonl": claudePair(id: "a", start: old)])
        await h.prober.start()
        // Give the loop a chance to run backfill, then assert nothing stored.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await h.writer.records.isEmpty)
    }
}

private extension AsyncStream {
    func first() async -> Element? {
        for await element in self { return element }
        return nil
    }
}
