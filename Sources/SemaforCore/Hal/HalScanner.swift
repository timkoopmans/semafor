import Foundation

public struct HalErrorRecord: Codable, Equatable, Sendable {
    public let code: Int
    public let at: Date
    public init(code: Int, at: Date) { self.code = code; self.at = at }
}

public actor HalScanner {
    public struct ScanState: Codable, Equatable, Sendable {
        /// Scan state format version. 2 = OpenCode `session_message` (spec §3.1
        /// amendment); loading any other version resets (legacy-table cursors
        /// are meaningless for the new table ⇒ one-off re-backfill).
        public static let currentSchemaVersion = 2

        public var cursor: Int64
        public var lastScan: Date?
        public var recentErrors: [HalErrorRecord]
        public var schemaVersion: Int
        public init(cursor: Int64 = 0, lastScan: Date? = nil, recentErrors: [HalErrorRecord] = [], schemaVersion: Int = ScanState.currentSchemaVersion) {
            self.cursor = cursor; self.lastScan = lastScan; self.recentErrors = recentErrors; self.schemaVersion = schemaVersion
        }

        private enum CodingKeys: String, CodingKey { case cursor, lastScan, recentErrors, schemaVersion }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cursor = try container.decode(Int64.self, forKey: .cursor)
            if let text = try container.decodeIfPresent(String.self, forKey: .lastScan) {
                guard let date = StoreDateCoding.parse(text) else {
                    throw DecodingError.dataCorruptedError(forKey: .lastScan, in: container, debugDescription: "Invalid lastScan date")
                }
                lastScan = date
            } else { lastScan = nil }
            recentErrors = try container.decode([HalErrorRecord].self, forKey: .recentErrors)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cursor, forKey: .cursor)
            try container.encodeIfPresent(lastScan.map(StoreDateCoding.render), forKey: .lastScan)
            try container.encode(recentErrors, forKey: .recentErrors)
            try container.encode(schemaVersion, forKey: .schemaVersion)
        }
    }

    /// Schema v2 `session_message.data` DTO (spec §3.1 amendment). `type`
    /// lives on the row column, not here. Privacy §8: `ErrorInfo` decodes
    /// only `type` + `status` — `message`/`response` are never decoded into
    /// any type, stored, or printed.
    private struct MessageData: Decodable {
        struct Model: Decodable { let id: String?; let providerID: String? }
        struct Tokens: Decodable { let output: Int? }
        struct Time: Decodable { let created: Int64?; let completed: Int64? }
        struct ErrorInfo: Decodable {
            let type: String?
            let status: Int?
            private enum CodingKeys: String, CodingKey { case type, status }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decode(String.self, forKey: .type)
                status = try? container.decode(Int.self, forKey: .status)
            }
        }
        let model: Model?; let tokens: Tokens?; let time: Time?; let error: ErrorInfo?
    }

    private let dbPath: String
    private let settings: AppSettings
    private let store: SampleStore
    private let stateURL: URL
    private var scanState: ScanState
    private var loopTask: Task<Void, Never>?
    private var scanning = false

    public init(dbPath: String, settings: AppSettings, store: SampleStore, stateURL: URL) {
        self.dbPath = dbPath; self.settings = settings; self.store = store; self.stateURL = stateURL
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(ScanState.self, from: data),
           decoded.schemaVersion == ScanState.currentSchemaVersion {
            scanState = decoded
        } else {
            scanState = ScanState()
        }
    }

    public func state() -> ScanState { scanState }

    public func recentErrors(now: Date, window: TimeInterval) -> [HalErrorRecord] {
        scanState.recentErrors.filter { $0.at >= now.addingTimeInterval(-window) }.sorted { $0.at > $1.at }
    }

    public func scanOnce(now: Date) async throws -> Int {
        // Reentrancy guard: the store.append below suspends, and a concurrent
        // scan (loop tick racing manual refresh) would re-read the cursor and
        // double-append error records, which have no dedupe key like samples.
        // Check-and-set is atomic here because it precedes the first suspension.
        if scanning { return 0 }
        scanning = true
        defer { scanning = false }
        let db = try OpenCodeDb(path: dbPath)
        let rows = try db.sessionMessages(after: scanState.cursor, limit: 2000)
        var count = 0
        for row in rows {
            guard let decoded = try? JSONDecoder().decode(MessageData.self, from: Data(row.data.utf8)) else { scanState.cursor = row.rowid; continue }
            let isHalAssistant = row.type == "assistant" && decoded.model?.providerID == "hal"
            if isHalAssistant, decoded.error == nil, decoded.time?.completed == nil { break }
            scanState.cursor = row.rowid
            guard isHalAssistant else { continue }
            if let error = decoded.error {
                // "aborted" is a user cancel, not a server fault (§3.3);
                // every other type — known or unknown — records code + time only.
                if error.type != "aborted", let created = decoded.time?.created {
                    let status = error.status
                    scanState.recentErrors.append(HalErrorRecord(code: status.map { $0 >= 400 ? $0 : 0 } ?? 0, at: Date(timeIntervalSince1970: Double(created) / 1000)))
                }
                continue
            }
            guard let created = decoded.time?.created, let completed = decoded.time?.completed else { continue }
            let output = decoded.tokens?.output
            let duration = Double(completed - created) / 1000
            let validDuration = (0.5...3600).contains(duration) ? duration : nil
            let sample = ProbeSample(provider: .hal, model: decoded.model?.id ?? "hal-unknown", sessionKey: "session_message#\(row.rowid)", ttft: nil, duration: validDuration, tokensPerSecond: validDuration.flatMap { duration in output.map { Double($0) / duration } }, tokens: output.flatMap { $0 >= 1 ? $0 : nil }, outcome: .ok, timestamp: Date(timeIntervalSince1970: Double(created) / 1000))
            try await store.append(.probe(sample)); count += 1
        }
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        scanState.recentErrors = Array(scanState.recentErrors.filter { $0.at >= cutoff }.sorted { $0.at > $1.at }.prefix(200))
        scanState.lastScan = now
        try saveState()
        return count
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Live gate (spec §5): keep ticking while hal is off so enabling
                // it in Settings picks up scans on the next tick, no restart.
                if self.settings.halEnabled {
                    do { _ = try await self.scanOnce(now: Date()) } catch { }
                }
                try? await Task.sleep(for: .seconds(max(1, self.settings.scanIntervalSeconds)))
            }
        }
    }

    private func saveState() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(scanState)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stateURL, options: .atomic)
    }
}
