import Foundation

/// Passive Codex measurement (spec §6.2): turn durations come from
/// `task_started`/`task_complete` pairs; throughput is reconstructed from
/// `token_count` cumulative bursts — adjacent events with `Δt ≤ burstGap` and
/// `Δtokens ≥ minTokenDelta` are generated-activity pairs, everything wider
/// is an idle/tool gap and must not dilute the rate (that is what turns a
/// lunch break into a false "crawl").
///
/// A turn that never sees `task_complete` emits nothing: still-running (or
/// abandoned) sessions stay silent rather than poison baselines.
public struct CodexLogExtractor: SessionLogExtracting {
    private static let futureSkew: TimeInterval = 300

    private struct OpenTurn {
        var id: String
        let fileName: String
        var startTs: Date
        var model: String?
        var firstItemTs: Date?
        var sawToolCall = false
        var acceptedTokens = 0
        var acceptedSeconds = 0.0
    }

    private struct CompletedTurn {
        let path: String
        let sampleStart: Date
        let sample: ProbeSample
    }

    private let burstGap: TimeInterval
    private let minTokenDelta: Int
    /// Last `token_count` per file — pairs span the whole file so a burst
    /// that starts mid-turn still anchors on the previous event.
    private var lastTokenEvent: [String: (ts: Date, tokens: Int)] = [:]
    private var openTurns: [String: OpenTurn] = [:]  // per file path
    private var fileModels: [String: String] = [:]
    private var completed: [CompletedTurn] = []

    public init(burstGap: TimeInterval = 30, minTokenDelta: Int = 5) {
        self.burstGap = burstGap
        self.minTokenDelta = minTokenDelta
    }

    public mutating func ingest(_ line: TailedLine) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.text.utf8)),
              let json = object as? [String: Any],
              let type = json["type"] as? String,
              let ts = LogTimeCoding.parse(json["timestamp"])
        else { return }
        let path = line.url.path

        switch type {
        case "session_meta":
            if let model = (json["payload"] as? [String: Any])?["model"] as? String,
               !model.isEmpty
            {
                fileModels[path] = model
            }

        case "turn_context":
            // Tolerant: attribute a model on turn_context to the open turn.
            guard var turn = openTurns[path],
                  let model = (json["payload"] as? [String: Any])?["model"] as? String,
                  !model.isEmpty
            else { return }
            turn.model = model
            openTurns[path] = turn

        case "event_msg":
            ingestEventMsg(line: line, json: json, ts: ts, path: path)

        case "response_item":
            guard var turn = openTurns[path],
                  let payloadType = (json["payload"] as? [String: Any])?["type"] as? String
            else { return }
            if payloadType == "function_call" || payloadType == "custom_tool_call" {
                turn.sawToolCall = true
            } else if turn.firstItemTs == nil {
                turn.firstItemTs = ts
            }
            openTurns[path] = turn

        default:
            return
        }
    }

    private mutating func ingestEventMsg(
        line: TailedLine, json: [String: Any], ts: Date, path: String
    ) {
        guard let payload = json["payload"] as? [String: Any],
              let eventType = payload["type"] as? String
        else { return }

        switch eventType {
        case "task_started":
            let attribution = payload["turn_attribution"] as? [String: Any]
            let turnId = (attribution?["turn_id"] as? String)
                ?? (payload["turn_id"] as? String)
                ?? "turn-\(line.url.lastPathComponent)-\(Int(ts.timeIntervalSince1970))"
            openTurns[path] = OpenTurn(
                id: turnId, fileName: line.url.lastPathComponent, startTs: ts,
                model: fileModels[path])

        case "token_count":
            recordTokenCount(payload: payload, ts: ts, path: path)

        case "task_complete":
            guard var turn = openTurns[path] else { return }
            // Adopt the completing event's own turn_id (it is the CLI's
            // canonical spelling when task_started only had an attribution).
            if let closedId = payload["turn_id"] as? String, closedId != turn.id {
                turn.id = closedId
            }
            complete(turn: &turn, at: ts, path: path)
            openTurns[path] = nil

        default:
            return
        }
    }

    private mutating func recordTokenCount(payload: [String: Any], ts: Date, path: String) {
        let usage = ((payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any])
        guard let tokens = (usage?["output_tokens"] as? NSNumber)?.intValue else { return }
        defer { lastTokenEvent[path] = (ts, tokens) }
        guard var turn = openTurns[path], let previous = lastTokenEvent[path] else { return }
        let deltaSeconds = ts.timeIntervalSince(previous.ts)
        let deltaTokens = tokens - previous.tokens
        guard deltaSeconds > 0, deltaSeconds <= burstGap, deltaTokens >= minTokenDelta else {
            return
        }
        turn.acceptedTokens += deltaTokens
        turn.acceptedSeconds += deltaSeconds
        openTurns[path] = turn
    }

    private mutating func complete(turn: inout OpenTurn, at completeTs: Date, path: String) {
        let ttft: TimeInterval?
        if turn.sawToolCall {
            ttft = nil  // first item was tool noise, not model output
        } else if let firstItemTs = turn.firstItemTs {
            ttft = max(0, firstItemTs.timeIntervalSince(turn.startTs))
        } else {
            ttft = nil
        }
        let tokensPerSecond: Double?
        if turn.acceptedSeconds > 0, turn.acceptedTokens >= minTokenDelta {
            tokensPerSecond = Double(turn.acceptedTokens) / turn.acceptedSeconds
        } else {
            tokensPerSecond = nil
        }
        // Honest count: accepted bursts only (rejected idle-gap deltas stay
        // rejected); nil when nothing was accepted rather than a fake 0.
        let tokens: Int? = turn.acceptedTokens > 0 ? turn.acceptedTokens : nil
        let sample = ProbeSample(
            provider: .codex,
            model: turn.model ?? "codex-unknown",
            sessionKey: "\(turn.fileName)#\(turn.id)",
            ttft: ttft,
            duration: max(0, completeTs.timeIntervalSince(turn.startTs)),
            tokensPerSecond: tokensPerSecond,
            tokens: tokens,
            outcome: .ok,
            timestamp: turn.startTs)
        completed.append(CompletedTurn(path: path, sampleStart: turn.startTs, sample: sample))
    }

    public mutating func finish(now: Date) -> [ProbeSample] {
        // Unclosed turns are simply absent from `completed` (spec §6.2).
        let emitted = completed
        completed = []
        return emitted
            .filter { $0.sampleStart.timeIntervalSince(now) <= Self.futureSkew }
            .map(\.sample)
            .sorted { $0.timestamp < $1.timestamp }
    }
}
