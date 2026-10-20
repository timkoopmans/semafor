import Foundation
import Testing
@testable import SemaforCore

/// Passive extraction from Claude Code session logs: `api-request` ↔
/// `assistant.requestRef` pairing, completion/dedupe rules, filtering
/// (spec §6.1/§7). Fixtures scrubbed of content; structural shape matches
/// the 2026-10-20 live exploration.
struct ClaudeLogExtractorTests {
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

    private let fixtureName = "claude-session-log.jsonl"

    private func lines() throws -> [TailedLine] {
        let data = try fixtureData(fixtureName)
        let url = URL(fileURLWithPath: "/fake/\(fixtureName)")
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { TailedLine(url: url, text: String($0)) }
    }

    @Test func fixtureYieldsExpectedSamples() throws {

        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        for line in try lines() { extractor.ingest(line) }
        let samples = extractor.finish(now: date("2026-10-20T12:00:00Z"))
        let byKey = Dictionary(uniqueKeysWithValues: samples.map { ($0.sessionKey, $0) })
        let name = fixtureName + "#"

        let health = try #require(byKey[name + "req-health"])
        #expect(health.outcome == .ok)
        #expect(health.ttft == 2.0)
        #expect(health.duration == 4.0)
        #expect(health.tokensPerSecond == 37.5)  // 150 tokens / 4 s
        #expect(health.tokens == 150)  // final cumulative usage count
        #expect(health.model == "claude-opus-5-5")
        #expect(health.timestamp == date("2026-10-20T03:00:00.000Z"))

        let crawl = try #require(byKey[name + "req-crawl"])
        #expect(crawl.ttft == 18.0)
        #expect(crawl.tokensPerSecond == 42.0 / 25.0)

        let dead = try #require(byKey[name + "req-dead"])  // superseded, no replies
        #expect(dead.outcome == .timeout)
        #expect(dead.ttft == nil && dead.duration == nil && dead.tokensPerSecond == nil)
        #expect(dead.model == "claude-opus-5-5")  // from params.model

        let tiny = try #require(byKey[name + "req-tiny"])
        #expect(tiny.tokensPerSecond == nil)  // under the 10-token floor
        #expect(tiny.ttft == 1.0)

        let orphan = try #require(byKey[name + "req-orphan"])
        #expect(orphan.outcome == .timeout)

        #expect(samples.count == 6)  // + req-after-dead; no summarizer, no future
        #expect(!samples.contains { $0.sessionKey.contains("summar") })
        #expect(!samples.contains { $0.sessionKey.contains("future") })
    }

    @Test func quietPeriodGatesCompletion() throws {
        let all = try lines()
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        for line in all {
            if line.text.contains("req-health") { extractor.ingest(line) }
        }
        // Last line at 03:00:04.0; only 1.5 s later ⇒ still "in flight".
        #expect(extractor.finish(now: date("2026-10-20T03:00:05.500Z")).isEmpty)
        let samples = extractor.finish(now: date("2026-10-20T03:00:06.100Z"))
        #expect(samples.count == 1)
        // Second finish emits nothing — completed pendings are dropped.
        #expect(extractor.finish(now: date("2026-10-20T03:00:07.000Z")).isEmpty)
    }

    @Test func pendingWithNoReplyAndNoSupersederIsSilent() throws {
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        extractor.ingest(TailedLine(url: URL(fileURLWithPath: "/f.jsonl"), text:
            #"{"type":"api-request","id":"r1","timestamp":"2026-10-20T04:00:00.000Z","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}"#))
        let samples = extractor.finish(now: date("2026-10-20T12:00:00Z"))
        #expect(samples.isEmpty)  // never-complete session ⇒ no poison sample
    }

    @Test func refeedingSameFileProducesIdenticalSessionKeys() throws {
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        let all = try lines()
        for line in all { extractor.ingest(line) }
        let first = extractor.finish(now: date("2026-10-20T12:00:00Z"))
        for line in all { extractor.ingest(line) }
        let second = extractor.finish(now: date("2026-10-20T12:00:00Z"))
        #expect(first.map(\.sessionKey).sorted() == second.map(\.sessionKey).sorted())
    }

    @Test func malformedLinesAreIgnoredNotFatal() throws {
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        let url = URL(fileURLWithPath: "/f.jsonl")
        extractor.ingest(TailedLine(url: url, text: "not json {{{"))
        extractor.ingest(TailedLine(url: url, text: #"{"type":"assistant","requestRef":"nope"}"#))
        extractor.ingest(TailedLine(url: url, text: #"{"noType":true}"#))
        #expect(extractor.finish(now: date("2026-10-20T12:00:00Z")).isEmpty)
    }

    @Test func nonISOTimestampLineSkipped() throws {
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        let url = URL(fileURLWithPath: "/f.jsonl")
        extractor.ingest(TailedLine(url: url, text:
            #"{"type":"api-request","id":"r9","timestamp":"yesterday","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}"#))
        extractor.ingest(TailedLine(url: url, text:
            #"{"type":"assistant","requestRef":"r9","timestamp":"today","message":{"model":"claude-opus-5-5","usage":{"output_tokens":40}}}"#))
        #expect(extractor.finish(now: date("2026-10-20T12:00:00Z")).isEmpty)
    }

    // MARK: - Token counts (7-day bar strip source)

    private func feed(_ extractor: inout ClaudeLogExtractor, _ text: String) {
        extractor.ingest(TailedLine(url: URL(fileURLWithPath: "/tokens.jsonl"), text: text))
    }

    @Test func completedSampleCarriesFinalTokenCount() {
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        feed(&extractor, #"{"type":"api-request","id":"t1","timestamp":"2026-10-20T03:00:00.000Z","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}"#)
        feed(&extractor, #"{"type":"assistant","requestRef":"t1","requestedModel":"claude-opus-5-5","timestamp":"2026-10-20T03:00:01.000Z","message":{"model":"claude-opus-5-5","usage":{"output_tokens":40}}}"#)
        feed(&extractor, #"{"type":"assistant","requestRef":"t1","requestedModel":"claude-opus-5-5","timestamp":"2026-10-20T03:00:02.000Z","message":{"model":"claude-opus-5-5","usage":{"output_tokens":80}}}"#)
        let samples = extractor.finish(now: date("2026-10-20T03:10:00Z"))
        #expect(samples.count == 1)
        #expect(samples[0].tokens == 80)  // final cumulative, not the max delta
        #expect(samples[0].tokensPerSecond == 40)
    }

    @Test func tinyCallStillRecordsTokensWithoutRate() {
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        feed(&extractor, #"{"type":"api-request","id":"t2","timestamp":"2026-10-20T03:00:00.000Z","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}"#)
        feed(&extractor, #"{"type":"assistant","requestRef":"t2","requestedModel":"claude-opus-5-5","timestamp":"2026-10-20T03:00:02.000Z","message":{"model":"claude-opus-5-5","usage":{"output_tokens":3}}}"#)
        let samples = extractor.finish(now: date("2026-10-20T03:10:00Z"))
        #expect(samples.count == 1)
        #expect(samples[0].tokens == 3)  // real count even below the rate floor
        #expect(samples[0].tokensPerSecond == nil)
    }

    @Test func stalledRequestHasNoTokenCount() {
        var extractor = ClaudeLogExtractor(quietPeriod: 2)
        feed(&extractor, #"{"type":"api-request","id":"stall","timestamp":"2026-10-20T03:00:00.000Z","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}"#)
        feed(&extractor, #"{"type":"api-request","id":"next","timestamp":"2026-10-20T03:01:00.000Z","querySource":"repl_main_thread","params":{"model":"claude-opus-5-5"}}"#)
        feed(&extractor, #"{"type":"assistant","requestRef":"next","requestedModel":"claude-opus-5-5","timestamp":"2026-10-20T03:01:01.000Z","message":{"model":"claude-opus-5-5","usage":{"output_tokens":50}}}"#)
        let samples = extractor.finish(now: date("2026-10-20T03:10:00Z"))
        guard let stalled = samples.first(where: { $0.sessionKey == "tokens.jsonl#stall" }) else {
            Issue.record("missing stall sample")
            return
        }
        #expect(stalled.outcome == .timeout)
        #expect(stalled.tokens == nil)
    }
}
