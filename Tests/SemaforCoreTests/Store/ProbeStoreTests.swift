import Foundation
import Testing
@testable import SemaforCore

/// Round-trip and query tests for the passive probe/control/status records (spec §11).
struct ProbeStoreTests {
    private static let dayOne = Date(timeIntervalSince1970: 1_760_832_000) // 2025-10-19T00:00:00Z
    private static let dayTwo = Date(timeIntervalSince1970: 1_760_918_400) // 2025-10-20T00:00:00Z

    private final class TimeBox: @unchecked Sendable { var date: Date = Date() }

    private func makeStore(date: Date) throws -> (SampleStore, URL, TimeBox) {
        let box = TimeBox()
        box.date = date
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semafor-probe-store-\(UUID().uuidString)")
        let store = SampleStore(config: .init(directory: dir, dateNow: { box.date }))
        return (store, dir, box)
    }

    private func iso(_ text: String) -> Date {
        func formatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            return f
        }
        guard let date = formatter([.withInternetDateTime, .withFractionalSeconds]).date(from: text)
            ?? formatter([.withInternetDateTime]).date(from: text) else {
            fatalError("bad test date \(text)")
        }
        return date
    }

    private func sample(
        provider: ProviderID = .claude,
        model: String = "claude-opus-5-5",
        sessionKey: String,
        ttft: TimeInterval? = 2.0,
        duration: TimeInterval? = 4.0,
        tokensPerSecond: Double? = 80,
        tokens: Int? = nil,
        outcome: ProbeOutcome = .ok,
        timestamp: Date
    ) -> ProbeSample {
        ProbeSample(
            provider: provider, model: model, sessionKey: sessionKey,
            ttft: ttft, duration: duration, tokensPerSecond: tokensPerSecond,
            tokens: tokens, outcome: outcome, timestamp: timestamp)
    }

    @Test func probeSampleRoundTripsAllFields() async throws {
        let (store, dir, _) = try makeStore(date: Self.dayOne)
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = sample(
            provider: .codex, model: "gpt-6-astra", sessionKey: "rollout-1#turn-9",
            ttft: 1.75, duration: 9.5, tokensPerSecond: 41.25, tokens: 312,
            timestamp: iso("2025-10-19T06:30:00Z"))
        try await store.append(.probe(expected))
        // Raw JSON check too: ProbeSample's encode is hand-rolled, so a field
        // present in decode but missing in encode must not slip through.
        let url = dir.appendingPathComponent("probes-2025-10-19.jsonl")
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains(#""tokens":312"#))
        let got = await store.probeSamples(provider: .codex, since: .distantPast)
        #expect(got == [expected])
    }

    @Test func probeOutcomeStreamFailureRoundTrips() async throws {
        let (store, dir, _) = try makeStore(date: Self.dayOne)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stalled = sample(sessionKey: "sess-a#req-1", ttft: nil, duration: nil,
                             tokensPerSecond: nil, outcome: .timeout,
                             timestamp: iso("2025-10-19T07:00:00Z"))
        let failed = sample(sessionKey: "sess-a#req-2", tokensPerSecond: nil,
                            outcome: .streamFailure, timestamp: iso("2025-10-19T07:01:00Z"))
        let auth = sample(sessionKey: "sess-a#req-3", outcome: .authError,
                          timestamp: iso("2025-10-19T07:02:00Z"))
        for s in [stalled, failed, auth] { try await store.append(.probe(s)) }
        let got = await store.probeSamples(provider: .claude, since: .distantPast)
        #expect(got.map(\.outcome) == [.timeout, .streamFailure, .authError])
        #expect(got[0].ttft == nil && got[0].duration == nil && got[0].tokensPerSecond == nil)
    }

    @Test func probeQueriesNarrowByModelAndSince() async throws {
        let (store, dir, _) = try makeStore(date: Self.dayOne)
        defer { try? FileManager.default.removeItem(at: dir) }
        let opusEarly = sample(sessionKey: "f#1", timestamp: iso("2025-10-19T01:00:00Z"))
        let opusLate = sample(sessionKey: "f#2", timestamp: iso("2025-10-19T05:00:00Z"))
        let sonnet = sample(model: "claude-sonnet-5-5", sessionKey: "f#3",
                            timestamp: iso("2025-10-19T06:00:00Z"))
        let codex = sample(provider: .codex, model: "gpt-6-astra", sessionKey: "f#4",
                           timestamp: iso("2025-10-19T06:30:00Z"))
        for s in [opusEarly, opusLate, sonnet, codex] { try await store.append(.probe(s)) }

        #expect(await store.probeSamples(provider: .claude, since: .distantPast).count == 3)
        #expect(await store.probeSamples(provider: .claude, model: "claude-sonnet-5-5",
                                   since: .distantPast) == [sonnet])
        let late = Date(timeIntervalSince1970: iso("2025-10-19T04:00:00Z").timeIntervalSince1970)
        #expect(await store.probeSamples(provider: .claude, since: late)
            .map(\.sessionKey) == ["f#2", "f#3"])
    }

    @Test func probeSamplesAscendAcrossDayFiles() async throws {
        let (store, dir, box) = try makeStore(date: Self.dayOne)
        defer { try? FileManager.default.removeItem(at: dir) }
        let early = sample(sessionKey: "f#early", timestamp: iso("2025-10-19T23:00:00Z"))
        try await store.append(.probe(early))
        box.date = Self.dayTwo
        let later = sample(sessionKey: "f#later", timestamp: iso("2025-10-20T01:00:00Z"))
        try await store.append(.probe(later))
        let got = await store.probeSamples(provider: .claude, since: .distantPast)
        #expect(got.map(\.sessionKey) == ["f#early", "f#later"])
    }

    @Test func duplicateSessionKeyKeepsNewestOnce() async throws {
        let (store, dir, _) = try makeStore(date: Self.dayOne)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = sample(sessionKey: "f#dup", tokensPerSecond: 10,
                           timestamp: iso("2025-10-19T01:00:00Z"))
        let newest = sample(sessionKey: "f#dup", tokensPerSecond: 55,
                            timestamp: iso("2025-10-19T01:00:00Z"))
        try await store.append(.probe(first))
        try await store.append(.probe(newest))
        let got = await store.probeSamples(provider: .claude, since: .distantPast)
        #expect(got.count == 1)
        #expect(got.first?.tokensPerSecond == 55)
    }

    @Test func controlAndStatusRecordsRoundTrip() async throws {
        let (store, dir, _) = try makeStore(date: Self.dayOne)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = ControlSample(provider: .claude, latency: 0.4,
                               timestamp: iso("2025-10-19T05:00:00Z"))
        let failed = ControlSample(provider: .claude, latency: nil,
                                   timestamp: iso("2025-10-19T05:05:00Z"))
        let codexControl = ControlSample(provider: .codex, latency: 1.2,
                                         timestamp: iso("2025-10-19T05:10:00Z"))
        for c in [ok, failed, codexControl] { try await store.append(.control(c)) }
        #expect(await store.controlSamples(since: .distantPast) == [ok, failed, codexControl])

        try await store.append(.status(.claude, .operational, fetchedAt: iso("2025-10-19T05:00:00Z")))
        try await store.append(.status(.claude, .degraded, fetchedAt: iso("2025-10-19T06:00:00Z")))
        #expect(await store.latestStatus(provider: .claude) == .degraded)
        #expect(await store.latestStatus(provider: .codex) == nil)
    }

    @Test func unknownAndTornProbeLinesCountCorrupt() async throws {
        let (store, dir, _) = try makeStore(date: Self.dayOne)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let valid = """
        {"probe":{"provider":"claude","model":"claude-opus-5-5","sessionKey":"f#ok",\
        "ttft":2.0,"duration":4.0,"tokensPerSecond":80.0,"outcome":"ok",\
        "timestamp":"2025-10-19T04:00:00Z"}}
        """
        let contents = valid + "\n" + #"{"mystery":{"a":1}}"# + "\n" + #"{"probe":{"prov"#
        try Data(contents.utf8).write(to: dir.appendingPathComponent("probes-2025-10-19.jsonl"))
        let got = await store.probeSamples(provider: .claude, since: .distantPast)
        #expect(got.count == 1)
        #expect(got.first?.sessionKey == "f#ok")
        #expect(await store.lastReadCorruptLineCount == 2)
    }
}
