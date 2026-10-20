import Foundation

public struct HalErrorRecord: Codable, Equatable, Sendable {
    public let code: Int
    public let at: Date
    public init(code: Int, at: Date) { self.code = code; self.at = at }
}

public actor HalScanner {
    public struct ScanState: Codable, Equatable, Sendable {
        public var cursor: Int64
        public var lastScan: Date?
        public var recentErrors: [HalErrorRecord]
        public init(cursor: Int64 = 0, lastScan: Date? = nil, recentErrors: [HalErrorRecord] = []) {
            self.cursor = cursor; self.lastScan = lastScan; self.recentErrors = recentErrors
        }

        private enum CodingKeys: String, CodingKey { case cursor, lastScan, recentErrors }

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
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cursor, forKey: .cursor)
            try container.encodeIfPresent(lastScan.map(StoreDateCoding.render), forKey: .lastScan)
            try container.encode(recentErrors, forKey: .recentErrors)
        }
    }

    private struct MessageData: Decodable {
        struct Tokens: Decodable { let output: Int? }
        struct Time: Decodable { let created: Int64?; let completed: Int64? }
        let role: String?; let providerID: String?; let modelID: String?
        let tokens: Tokens?; let time: Time?; let error: ErrorInfo?
        struct ErrorInfo: Decodable { let name: String?; let data: ErrorPayload? }
        struct ErrorPayload: Decodable {
            let statusCode: Int?
            private enum CodingKeys: String, CodingKey { case statusCode }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                statusCode = try? container.decode(Int.self, forKey: .statusCode)
            }
        }
    }

    private let dbPath: String
    private let settings: AppSettings
    private let store: SampleStore
    private let stateURL: URL
    private var scanState: ScanState
    private var loopTask: Task<Void, Never>?

    public init(dbPath: String, settings: AppSettings, store: SampleStore, stateURL: URL) {
        self.dbPath = dbPath; self.settings = settings; self.store = store; self.stateURL = stateURL
        if let data = try? Data(contentsOf: stateURL), let decoded = try? JSONDecoder().decode(ScanState.self, from: data) { scanState = decoded }
        else { scanState = ScanState() }
    }

    public func state() -> ScanState { scanState }

    public func recentErrors(now: Date, window: TimeInterval) -> [HalErrorRecord] {
        scanState.recentErrors.filter { $0.at >= now.addingTimeInterval(-window) }.sorted { $0.at > $1.at }
    }

    public func scanOnce(now: Date) async throws -> Int {
        let db = try OpenCodeDb(path: dbPath)
        let rows = try db.rows(after: scanState.cursor, limit: 1000)
        var count = 0
        for row in rows {
            guard let decoded = try? JSONDecoder().decode(MessageData.self, from: Data(row.data.utf8)) else { scanState.cursor = row.rowid; continue }
            if decoded.role == "assistant", decoded.providerID == "hal", decoded.error == nil, decoded.time?.completed == nil { break }
            scanState.cursor = row.rowid
            if let error = decoded.error {
                guard decoded.role == "assistant", decoded.providerID == "hal" else { continue }
                if error.name != "MessageAbortedError", let created = decoded.time?.created {
                    let statusCode = error.data?.statusCode
                    if statusCode == nil || statusCode! >= 400 {
                        scanState.recentErrors.append(HalErrorRecord(code: statusCode ?? 0, at: Date(timeIntervalSince1970: Double(created) / 1000)))
                    }
                }
                continue
            }
            guard decoded.role == "assistant", decoded.providerID == "hal", decoded.error == nil,
                  let created = decoded.time?.created, let completed = decoded.time?.completed else { continue }
            let output = decoded.tokens?.output
            let duration = Double(completed - created) / 1000
            let validDuration = (0.5...3600).contains(duration) ? duration : nil
            let sample = ProbeSample(provider: .hal, model: decoded.modelID ?? "hal-unknown", sessionKey: "opencode.db#\(row.rowid)", ttft: nil, duration: validDuration, tokensPerSecond: validDuration.flatMap { duration in output.map { Double($0) / duration } }, tokens: output.flatMap { $0 >= 1 ? $0 : nil }, outcome: .ok, timestamp: Date(timeIntervalSince1970: Double(created) / 1000))
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
