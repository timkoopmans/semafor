import Foundation
import SemaforCore

// Opt-in live endpoint tool: exercises the real providers against the real
// on-machine credentials and prints decoded windows, optionally the
// credential-scrubbed raw body. Usage:
//   swift run SemaforSmoke claude|codex [--raw]

let arguments = Array(CommandLine.arguments.dropFirst())

let providerID: ProviderID
switch arguments.first {
case "codex": providerID = .codex
case "claude", .none: providerID = .claude
case let other?:
    FileHandle.standardError.write(Data("unknown provider: \(other) (expected claude or codex)\n".utf8))
    exit(2)
}
let rawRequested = arguments.contains("--raw")

let settings = AppSettings(defaults: UserDefaults(suiteName: "com.timkoopmans.semafor.smoke")!)
let http = URLSessionHTTPClient(timeout: 20)

func makeProvider() -> any Provider {
    switch providerID {
    case .claude:
        ClaudeProvider(http: http, credentials: ClaudeKeychainReader(), settings: settings)
    case .codex:
        CodexProvider(http: http, auth: CodexFileReader(), settings: settings)
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
