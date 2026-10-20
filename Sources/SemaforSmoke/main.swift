import Foundation
import SemaforCore

// Opt-in live tools. Usage:
//   swift run SemaforSmoke claude|codex [--raw]          — live endpoint check
//   swift run SemaforSmoke scan claude|codex|hal [--days N] — passive extractor
//     shape-check against this machine's real session logs / OpenCode db
//     (numbers and model slugs only, everything through redact(); exit 0 iff
//     ≥ 1 sample). hal has no live endpoint, so it scans only.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "scan" {
    await runLiveScan(arguments: Array(arguments.dropFirst()))
    exit(0)
}

let providerID: ProviderID
switch arguments.first {
case "codex": providerID = .codex
case "claude", .none: providerID = .claude
case let other?:
    // hal deliberately not accepted here: no limits endpoint to check live.
    FileHandle.standardError.write(Data("unknown provider: \(other) (expected claude or codex)\n".utf8))
    exit(2)
}
let rawRequested = arguments.contains("--raw")

let settings = AppSettings(defaults: UserDefaults(suiteName: "com.timkoopmans.semafor.smoke")!)
let http = URLSessionHTTPClient(timeout: 20)

func unsupportedHal() -> Never {
    FileHandle.standardError.write(Data("hal has no limits endpoint (health probe only)\n".utf8))
    exit(2)
}

func makeProvider() -> any Provider {
    switch providerID {
    case .claude:
        ClaudeProvider(http: http, credentials: ClaudeKeychainReader(), settings: settings)
    case .codex:
        CodexProvider(http: http, auth: CodexFileReader(), settings: settings)
    case .hal:
        unsupportedHal()
    }
}

do {
    let windows = try await makeProvider().fetchLimits()
    print("[\(providerID.rawValue)] \(windows.count) window(s) fetched \(ISO8601DateFormatter().string(from: Date()))")
    for window in windows {
        let percent = window.usedPercent.map { String(format: "%.1f%%", $0) } ?? "not reported"
        let reset = window.resetsAt.map { "in \(Int($0.timeIntervalSinceNow / 60)) min" } ?? "unknown"
        print("  \(window.name.rawValue): \(percent), resets \(reset), window \(window.windowSeconds.map(String.init) ?? "?")s")
    }
} catch let error as ProviderError {
    FileHandle.standardError.write(Data("provider error: \(error)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("unexpected error: \(error)\n".utf8))
    exit(1)
}

if rawRequested {
    // Second, single-shot fetch for the diagnostic body only; credential
    // headers are assembled here because this is the raw diagnostic path.
    let url: URL
    var headers: [String: String]
    do {
        switch providerID {
        case .claude:
            url = ClaudeProvider.usageURL
            headers = ["anthropic-beta": "oauth-2025-04-20"]
            headers["Authorization"] = "Bearer \(try ClaudeKeychainReader().accessToken())"
        case .codex:
            url = CodexProvider.usageURL
            let tokens = try CodexFileReader().tokens()
            headers = ["Authorization": "Bearer \(tokens.accessToken)"]
            if let accountId = tokens.accountId {
                headers["chatgpt-account-id"] = accountId
            }
        case .hal:
            unsupportedHal()
        }

        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, _) = try await URLSessionHTTPClient(timeout: 20).data(for: request)
        print("--- raw (credential-scrubbed) ---")
        print(redact(String(decoding: data, as: UTF8.self)))
    } catch {
        FileHandle.standardError.write(Data("raw fetch failed: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Live scan

func runLiveScan(arguments: [String]) async {
    let providerID: ProviderID
    switch arguments.first {
    case "codex": providerID = .codex
    case "claude", .none: providerID = .claude
    case "hal": providerID = .hal
    case let other?:
        FileHandle.standardError.write(Data("unknown provider: \(other) (expected claude, codex or hal)\n".utf8))
        exit(2)
    }
    var days = 7
    if let daysIndex = arguments.firstIndex(of: "--days"),
       let parsed = arguments.dropFirst(daysIndex + 1).first.flatMap(Int.init)
    {
        days = max(1, parsed)
    }
    if providerID == .hal {
        await runHalScan(days: days)
        return
    }

    let settings = AppSettings(defaults: UserDefaults(suiteName: "com.timkoopmans.semafor.smoke.scan")!)
    let scanProvider: any Provider = {
        let http = URLSessionHTTPClient(timeout: 5)
        switch providerID {
        case .claude:
            return ClaudeProvider(http: http, credentials: ClaudeKeychainReader(), settings: settings)
        case .codex:
            return CodexProvider(http: http, auth: CodexFileReader(), settings: settings)
        case .hal:
            unsupportedHal()
        }
    }()

    // Throwaway tailer: temp state file so the live app's offsets stay put.
    let tailer = SessionLogTailer(
        stateURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("semafor-live-scan-\(UUID().uuidString).json"))
    await tailer.loadState()
    var extractor: any SessionLogExtracting = providerID == .claude
        ? ClaudeLogExtractor() : CodexLogExtractor()

    let lines = await tailer.pendingLines(in: scanProvider.sessionLogPaths, namePattern: "*.jsonl")
    for line in lines {
        extractor.ingest(line)
    }
    let now = Date()
    var samples = extractor.finish(now: now)
    let windowStart = now.addingTimeInterval(-Double(days) * 86_400)
    samples = samples.filter { $0.timestamp >= windowStart && $0.timestamp <= now }

    print(redact("[scan] \(providerID.rawValue): tailed \(lines.count) new line(s), \(samples.count) sample(s) in last \(days)d"))
    let byModel = Dictionary(grouping: samples, by: \.model)
    for model in byModel.keys.sorted() {
        let group = byModel[model]!
        let ttfts = group.compactMap(\.ttft).sorted()
        let rates = group.compactMap(\.tokensPerSecond).sorted()
        let timeouts = group.filter { $0.outcome == .timeout }.count
        let ttftText = ttfts.isEmpty ? "–"
            : "p50 \(String(format: "%.2f s", percentile(ttfts, 0.50))) p90 \(String(format: "%.2f s", percentile(ttfts, 0.90)))"
        let rateText = rates.isEmpty ? "–"
            : "p50 \(String(format: "%.1f tok/s", percentile(rates, 0.50)))"
        print(redact("  \(model): n=\(group.count) ttft \(ttftText) \(rateText) timeouts=\(timeouts)"))
    }
    if samples.isEmpty {
        FileHandle.standardError.write(Data("scan produced no samples — check extractor rules\n".utf8))
        exit(1)
    }
}

/// One-shot HalScanner pass over the real OpenCode db against throwaway
/// state and store in temporaryDirectory (unique per run), so the live app's
/// scan cursor and sample files are never touched. Counts and percentiles
/// only — no row content, everything through redact().
func runHalScan(days: Int) async {
    // Real user settings for the db path, same fallback rule as the app.
    let settings = AppSettings()
    let dbPath = settings.halDbPath.isEmpty
        ? NSHomeDirectory() + "/.local/share/opencode/opencode.db"
        : settings.halDbPath
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("semafor-smoke-hal-scan-\(UUID().uuidString)", isDirectory: true)
    let store = SampleStore(config: .init(directory: dir))
    let scanner = HalScanner(
        dbPath: dbPath, settings: settings, store: store,
        stateURL: dir.appendingPathComponent("scan-state.json"))
    let now = Date()
    do {
        // scanOnce consumes ≤ 1000 rows per call: drain the whole db by
        // repeating until the cursor stops moving (exhausted, or parked on
        // one in-flight assistant row).
        for _ in 0..<1_000 {
            let before = await scanner.state().cursor
            _ = try await scanner.scanOnce(now: now)
            if await scanner.state().cursor == before { break }
        }
    } catch {
        FileHandle.standardError.write(Data(redact("hal scan failed: \(error)\n").utf8))
        exit(1)
    }
    let windowStart = now.addingTimeInterval(-Double(days) * 86_400)
    let samples = await store.probeSamples(provider: .hal, since: windowStart)
        .filter { $0.timestamp <= now }
    print(redact("[scan] hal: cursor \(await scanner.state().cursor), \(samples.count) sample(s) in last \(days)d"))
    let byModel = Dictionary(grouping: samples, by: \.model)
    for model in byModel.keys.sorted() {
        let group = byModel[model]!
        let rates = group.compactMap(\.tokensPerSecond).sorted()
        let rateText = rates.isEmpty ? "–"
            : "p50 \(String(format: "%.1f tok/s", percentile(rates, 0.50)))"
            + " p90 \(String(format: "%.1f tok/s", percentile(rates, 0.90)))"
        print(redact("  \(model): n=\(group.count) tok/s \(rateText)"))
    }
    // Error-code histogram: codes and counts only, never row content.
    // (recentErrors is the scanner's rolling 7-day buffer, so a window
    // beyond that shows only its tail.)
    let errors = await scanner.recentErrors(now: now, window: Double(days) * 86_400)
    let byCode = Dictionary(grouping: errors, by: \.code).mapValues(\.count)
    if byCode.isEmpty {
        print(redact("  no hal error rows captured in window"))
    }
    for code in byCode.keys.sorted() {
        print(redact("  error \(code) => \(byCode[code]!)"))
    }
    if samples.isEmpty {
        FileHandle.standardError.write(Data("hal scan produced no samples — check the db path\n".utf8))
        exit(1)
    }
}

func percentile(_ sorted: [Double], _ q: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int((q * Double(sorted.count)).rounded(.down))))
    return sorted[index]
}
