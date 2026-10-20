import Foundation

/// Passive Claude Code measurement (spec §6.1): pairs `api-request` lines
/// with their streamed `assistant` lines via `requestRef`.
///
/// Completion rules (spec §7): a request's sample is emitted only once the
/// stream looks complete — ≥ 1 assistant line and quiet for `quietPeriod`, or
/// superseded by a later main-thread request. A superseded request with zero
/// replies is a stall ⇒ one `.timeout` sample; an unfinished request with no
/// superseder stays silent (aborted sessions must not poison baselines).
/// Only main-thread traffic counts; non-JSON and unparseable-timestamp lines
/// are skipped, never fatal.
public struct ClaudeLogExtractor: SessionLogExtracting {
    /// Requests started more than this far in the future are clock anomalies.
    private static let futureSkew: TimeInterval = 300
    private static let minTokensForThroughput = 10
    private static let minSecondsForThroughput: TimeInterval = 0.5
    private static let mainThreadSource = "repl_main_thread"

    private struct Pending {
        let path: String
        let fileName: String
        let requestKey: String
        var startTs: Date
        var lastTouch: Date
        var model: String?
        var firstTs: Date?
        var lastAssistantTs: Date?
        var tokens: Int?
    }

    private let quietPeriod: TimeInterval
    private var pendings: [String: Pending] = [:]
    /// Latest main-thread request start per file, for supersede detection.
    private var latestRequestStart: [String: Date] = [:]
    private var ignoredKeys: Set<String> = []

    public init(quietPeriod: TimeInterval = 2) {
        self.quietPeriod = quietPeriod
    }

    public mutating func ingest(_ line: TailedLine) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.text.utf8)),
              let json = object as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "api-request": ingestRequest(line: line, json: json)
        case "assistant": ingestAssistant(line: line, json: json)
        default: return
        }
    }

    private mutating func ingestRequest(line: TailedLine, json: [String: Any]) {
        guard let requestKey = json["id"] as? String,
              let startTs = LogTimeCoding.parse(json["timestamp"])
        else { return }
        let path = line.url.path
        let key = "\(path)|\(requestKey)"

        if let source = json["querySource"] as? String, source != Self.mainThreadSource {
            ignoredKeys.insert(key)  // background traffic; also ignore its replies
            return
        }
        let paramsModel = (json["params"] as? [String: Any])?["model"] as? String
        pendings[key] = Pending(
            path: path, fileName: line.url.lastPathComponent, requestKey: requestKey,
            startTs: startTs, lastTouch: startTs, model: paramsModel,
            firstTs: nil, lastAssistantTs: nil, tokens: nil)
        if let latest = latestRequestStart[path], latest >= startTs { return }
        latestRequestStart[path] = startTs
    }

    private mutating func ingestAssistant(line: TailedLine, json: [String: Any]) {
        guard let requestRef = json["requestRef"] as? String else { return }
        let key = "\(line.url.path)|\(requestRef)"
        guard !ignoredKeys.contains(key), var pending = pendings[key],
              let ts = LogTimeCoding.parse(json["timestamp"])
        else { return }

        if pending.firstTs == nil || ts < pending.firstTs! { pending.firstTs = ts }
        if pending.lastAssistantTs == nil || ts > pending.lastAssistantTs! {
            pending.lastAssistantTs = ts
        }
        if ts > pending.lastTouch { pending.lastTouch = ts }

        let message = json["message"] as? [String: Any]
        if let model = (json["requestedModel"] as? String) ?? (message?["model"] as? String),
           !model.isEmpty
        {
            pending.model = model
        }
        if let usage = message?["usage"] as? [String: Any],
           let tokens = (usage["output_tokens"] as? NSNumber)?.intValue,
           pending.tokens == nil || tokens > pending.tokens!
        {
            pending.tokens = tokens
        }
        pendings[key] = pending
    }

    public mutating func finish(now: Date) -> [ProbeSample] {
        var samples: [ProbeSample] = []
        for (key, pending) in pendings where now.timeIntervalSince(pending.lastTouch) >= quietPeriod {
            if pending.startTs.timeIntervalSince(now) > Self.futureSkew {
                pendings[key] = nil  // future-dated clock anomaly ⇒ drop
                continue
            }
            if pending.firstTs == nil {
                guard superseded(pending), let stalled = timeoutSample(pending) else { continue }
                samples.append(stalled)
            } else if let completed = completeSample(pending) {
                samples.append(completed)
            } else {
                continue
            }
            pendings[key] = nil
        }
        return samples.sorted { $0.timestamp < $1.timestamp }
    }

    private func superseded(_ pending: Pending) -> Bool {
        guard let latest = latestRequestStart[pending.path] else { return false }
        return latest > pending.startTs
    }

    private func timeoutSample(_ pending: Pending) -> ProbeSample? {
        ProbeSample(
            provider: .claude,
            model: pending.model ?? "claude-unknown",
            sessionKey: "\(pending.fileName)#\(pending.requestKey)",
            ttft: nil, duration: nil, tokensPerSecond: nil,
            outcome: .timeout,
            timestamp: pending.startTs)
    }

    private func completeSample(_ pending: Pending) -> ProbeSample? {
        guard let firstTs = pending.firstTs, let lastTs = pending.lastAssistantTs else {
            return nil
        }
        let ttft = firstTs.timeIntervalSince(pending.startTs)
        let duration = lastTs.timeIntervalSince(pending.startTs)
        let tokensPerSecond: Double?
        if let tokens = pending.tokens,
           tokens >= Self.minTokensForThroughput,
           duration >= Self.minSecondsForThroughput
        {
            tokensPerSecond = Double(tokens) / duration
        } else {
            tokensPerSecond = nil
        }
        return ProbeSample(
            provider: .claude,
            model: pending.model ?? "claude-unknown",
            sessionKey: "\(pending.fileName)#\(pending.requestKey)",
            ttft: ttft,
            duration: duration,
            tokensPerSecond: tokensPerSecond,
            outcome: .ok,
            timestamp: pending.startTs)
    }
}
