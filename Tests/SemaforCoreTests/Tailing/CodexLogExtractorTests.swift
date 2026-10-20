import Foundation
import Testing
@testable import SemaforCore

/// Passive Codex measurement: turn durations from `task_started`/
/// `task_complete` and burst-filtered throughput from `token_count` deltas
/// (spec §6.2). The idle-gap case is the Review Focus artefact: raw
/// Δtokens/Δt across the pause reads ~0.3 tok/s; the burst filter must
/// recover the fast-burst rate instead of screaming "crawl".
struct CodexLogExtractorTests {
    private func date(_ text: String) -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let parsed = withFraction.date(from: text) ?? plain.date(from: text) else {
            fatalError("bad date \(text)")
        }
        return parsed
    }

    private let fixtureName = "codex-rollout.jsonl"

    private func lines(name: String = "codex-rollout.jsonl") throws -> [TailedLine] {
        let data = try fixtureData(fixtureName)
        let url = URL(fileURLWithPath: "/fake/\(name)")
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { TailedLine(url: url, text: String($0)) }
    }

    private func drainFixture() throws -> [ProbeSample] {
        var extractor = CodexLogExtractor()
        for line in try lines() { extractor.ingest(line) }
        return extractor.finish(now: date("2026-10-20T12:00:00Z"))
    }

    @Test func healthyTurnMeasuresTTFTDurationAndBurstRate() throws {
        let samples = try drainFixture()
        let byKey = Dictionary(uniqueKeysWithValues: samples.map { ($0.sessionKey, $0) })
        let healthy = try #require(byKey[fixtureName + "#turn-healthy"])
        #expect(healthy.outcome == .ok)
        #expect(healthy.provider == .codex)
        #expect(healthy.model == "gpt-6-astra")  // from session_meta
        #expect(healthy.timestamp == date("2026-10-20T02:00:45.567Z"))
        #expect(abs(healthy.ttft! - 1.933) < 0.001)  // first response_item − start
        #expect(abs(healthy.duration! - 9.433) < 0.001)  // task_complete − start
        // Accepted burst only: 100 tokens over the one adjacent 5 s pair.
        #expect(healthy.tokensPerSecond == 20)
        #expect(healthy.tokens == 100)  // accepted-burst total, not rate×duration
    }

    @Test func toolCallTurnHasNoTTFTButKeepsThroughput() throws {
        let samples = try drainFixture()
        let byKey = Dictionary(uniqueKeysWithValues: samples.map { ($0.sessionKey, $0) })
        let tools = try #require(byKey[fixtureName + "#turn-tools"])
        #expect(tools.ttft == nil)  // function_call seen ⇒ TTFT proxy invalid
        #expect(tools.duration == 14.0)
        #expect(tools.tokensPerSecond == 10)  // 50 tokens / 5 s
        #expect(tools.tokens == 50)
    }

    @Test func idleGapIsBurstFilteredNotCrawl() throws {
        let samples = try drainFixture()
        let byKey = Dictionary(uniqueKeysWithValues: samples.map { ($0.sessionKey, $0) })
        let gap = try #require(byKey[fixtureName + "#turn-gap"])
        // Raw would be 70 tokens / 255 s ≈ 0.27 tok/s. Burst-filtered:
        // 60/5 s + 10/5 s accepted ⇒ Σ70 / Σ10 s = 7.
        #expect(gap.tokensPerSecond == 7)
        if let tps = gap.tokensPerSecond {
            #expect(tps > 5)  // nowhere near the raw-across-idle artefact
        }
    }

    @Test func unclosedTurnEmitsNothing() throws {
        let samples = try drainFixture()
        #expect(samples.count == 3)  // healthy, tools, gap — not turn-open
        #expect(!samples.contains { $0.sessionKey.contains("turn-open") })
    }

    @Test func turnContextModelOverridesFileModel() throws {
        var extractor = CodexLogExtractor()
        let url = URL(fileURLWithPath: "/f/rollout-x.jsonl")
        func feed(_ text: String) { extractor.ingest(TailedLine(url: url, text: text)) }
        feed(#"{"timestamp":"2026-10-20T02:00:00.000Z","type":"session_meta","payload":{"model":"gpt-6-astra"}}"#)
        feed(#"{"timestamp":"2026-10-20T02:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_id":"t1"}}}"#)
        feed(#"{"timestamp":"2026-10-20T02:00:01.500Z","type":"turn_context","payload":{"model":"gpt-6-astra-preview"}}"#)
        feed(#"{"timestamp":"2026-10-20T02:00:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#)
        let samples = extractor.finish(now: date("2026-10-20T12:00:00Z"))
        #expect(samples.count == 1)
        #expect(samples.first?.model == "gpt-6-astra-preview")
        #expect(samples.first?.tokensPerSecond == nil)  // no token bursts
        #expect(samples.first?.tokens == nil)
    }

    @Test func refeedingSameFileProducesIdenticalSessionKeys() throws {
        var extractor = CodexLogExtractor()
        let all = try lines()
        for line in all { extractor.ingest(line) }
        let first = extractor.finish(now: date("2026-10-20T12:00:00Z"))
        for line in all { extractor.ingest(line) }
        let second = extractor.finish(now: date("2026-10-20T12:00:00Z"))
        #expect(first.map(\.sessionKey).sorted() == second.map(\.sessionKey).sorted())
    }

    @Test func garbageAndStrayEventsIgnored() throws {
        var extractor = CodexLogExtractor()
        let url = URL(fileURLWithPath: "/f.jsonl")
        func feed(_ text: String) { extractor.ingest(TailedLine(url: url, text: text)) }
        feed("not json {{{")
        feed(#"{"type":"weird","timestamp":"2026-10-20T02:00:00Z"}"#)
        // token_count with no open turn, then a task_complete with no turn.
        feed(#"{"timestamp":"2026-10-20T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"output_tokens":999}}}}"#)
        feed(#"{"timestamp":"2026-10-20T02:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"ghost"}}}"#)
        #expect(extractor.finish(now: date("2026-10-20T12:00:00Z")).isEmpty)
    }

    @Test func futureDatedTurnSkipped() throws {
        var extractor = CodexLogExtractor()
        let url = URL(fileURLWithPath: "/f.jsonl")
        func feed(_ text: String) { extractor.ingest(TailedLine(url: url, text: text)) }
        feed(#"{"timestamp":"2027-10-20T02:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_id":"t-space"}}}"#)
        feed(#"{"timestamp":"2027-10-20T02:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t-space"}}}"#)
        #expect(extractor.finish(now: date("2026-10-20T12:00:00Z")).isEmpty)
    }
}
