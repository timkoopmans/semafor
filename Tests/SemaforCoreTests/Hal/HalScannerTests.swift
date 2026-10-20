import Foundation
import Testing
@testable import SemaforCore

private func halTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HalScanner.\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Schema v2 fixture (spec §3.1 amendment): the desktop app's live table.
private func fixture(_ dir: URL) throws -> OpenCodeDb {
    let db = try OpenCodeDb(path: dir.appendingPathComponent("opencode.db").path, readOnly: false)
    try db.exec("CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT NOT NULL)")
    return db
}

private func insert(_ data: String, into db: OpenCodeDb, type: String = "assistant") throws {
    let escapedData = data.replacingOccurrences(of: "'", with: "''")
    let escapedType = type.replacingOccurrences(of: "'", with: "''")
    try db.exec("INSERT INTO session_message(type, data) VALUES ('\(escapedType)', '\(escapedData)')")
}

private func store(_ dir: URL, now: Date) -> SampleStore {
    SampleStore(config: .init(directory: dir, dateNow: { now }))
}

@Suite("HalScanner")
struct HalScannerTests {
    @Test func emitsSamplesWithSpecFields() async throws {
        let dir = try halTemp(), db = try fixture(dir)
        let t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal","variant":"default"},"tokens":{"output":180},"time":{"created":\#(t),"completed":\#(t + 2931)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t) / 1000)
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir.appendingPathComponent("store"), now: now), stateURL: dir.appendingPathComponent("state.json"))
        #expect(try await s.scanOnce(now: now) == 1)
        let samples = await store(dir.appendingPathComponent("store"), now: now).probeSamples(provider: .hal, since: .distantPast)
        #expect(samples.count == 1)
        #expect(samples.first?.ttft == nil)
        #expect(samples.first?.duration == 2.931)
        #expect(abs((samples.first?.tokensPerSecond ?? 0) - 180 / 2.931) < 0.01)
        #expect(samples.first?.tokens == 180)
        #expect(samples.first?.model == "m")
        // v2 keys must not collide with legacy "opencode.db#N" lines (store dedupes by key).
        #expect(samples.first?.sessionKey == "session_message#1")
        #expect(samples.first?.timestamp == now)
        let stateJSON = String(decoding: try Data(contentsOf: dir.appendingPathComponent("state.json")), as: UTF8.self)
        #expect(stateJSON.contains("\"lastScan\":\""))
        #expect(stateJSON.contains("T") && stateJSON.contains("Z"))
        #expect(stateJSON.contains("\"schemaVersion\":2"))
    }

    @Test func nonHalAndNonAssistantIgnoredButConsumed() async throws {
        let dir = try halTemp(), db = try fixture(dir), t = 1_760_000_000_000
        try insert(#"{"model":{"providerID":"hal"},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db, type: "user")
        try insert(#"{"model":{"id":"m","providerID":"other"},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir.appendingPathComponent("store"), now: Date()), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        #expect(await s.state().cursor == 2)
    }

    @Test func malformedJsonConsumedNotStalled() async throws {
        let dir = try halTemp(), db = try fixture(dir)
        try insert("not json", into: db)
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: Date()), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        #expect(await s.state().cursor == 1)
    }

    @Test func errorPayloadIsConsumedWithoutSample() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.invalid-request","message":"bad request","status":400,"response":{"body":"nope"}},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        let st = store(dir.appendingPathComponent("store"), now: Date())
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        let cursor = await s.state().cursor
        #expect(cursor == 1)
        #expect(await st.probeSamples(provider: .hal, since: .distantPast).isEmpty)
    }

    @Test func abortedMessagesInvisible() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"aborted","message":"user cancelled"},"time":{"created":\#(t)}}"#, into: db)
        let st = store(dir, now: Date()), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        #expect(await st.probeSamples(provider: .hal, since: .distantPast).isEmpty)
        #expect(await s.recentErrors(now: Date(), window: 100_000).isEmpty)
        #expect(await s.state().cursor == 1)
    }

    @Test func apiErrorRecordedNotSampled() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.error","message":"busy","status":429,"response":{"retryable":true}},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), st = store(dir, now: Date()), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await st.probeSamples(provider: .hal, since: .distantPast).isEmpty)
        let records = await s.recentErrors(now: now, window: 200)
        #expect(records == [HalErrorRecord(code: 429, at: Date(timeIntervalSince1970: Double(t) / 1000))])
    }

    @Test func garbageStatusCodeRecordsZero() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.transport","status":"bad"},"time":{"created":\#(t)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: now), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await s.recentErrors(now: now, window: 200).first?.code == 0)
    }

    @Test func otherProviderErrorsIgnoredButHalErrorsRecorded() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"other"},"error":{"type":"provider.error","status":500},"time":{"created":\#(t)}}"#, into: db)
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.error","status":429},"time":{"created":\#(t + 1000)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: now), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await s.state().cursor == 2)
        #expect(await s.state().recentErrors.map(\.code) == [429])
    }

    @Test func belowThresholdErrorIgnored() async throws {
        // Statuses below the 400 server-fault threshold are ignored as codes:
        // the record keeps the timestamp but carries code 0.
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.error","status":307},"time":{"created":\#(t)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: now), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await s.state().cursor == 1)
        let records = await s.state().recentErrors
        #expect(records.map(\.code) == [0])
        #expect(records.first?.at == Date(timeIntervalSince1970: Double(t) / 1000))
    }

    @Test func recordsPersistAndPrune() async throws {
        let dir = try halTemp(); _ = try fixture(dir)
        let state = dir.appendingPathComponent("state"), dbPath = dir.appendingPathComponent("opencode.db").path
        let old = Date(timeIntervalSince1970: 1_700_000_000), recent = Date(timeIntervalSince1970: 1_760_000_000)
        let seeded = HalScanner.ScanState(cursor: 0, recentErrors: [HalErrorRecord(code: 1, at: old)] + (0..<5).map { HalErrorRecord(code: $0 + 10, at: recent.addingTimeInterval(Double($0))) })
        try JSONEncoder().encode(seeded).write(to: state)
        let now = Date(timeIntervalSince1970: 1_760_000_100), s = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: now), stateURL: state)
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await s.state().recentErrors.map(\.code) == [14, 13, 12, 11, 10])
    }

    @Test func recordsPersistAndCapAtTwoHundred() async throws {
        let dir = try halTemp(); _ = try fixture(dir)
        let state = dir.appendingPathComponent("state"), dbPath = dir.appendingPathComponent("opencode.db").path
        let recent = Date(timeIntervalSince1970: 1_760_000_000)
        let seeded = HalScanner.ScanState(cursor: 0, recentErrors: (0..<250).map { HalErrorRecord(code: $0, at: recent.addingTimeInterval(Double($0))) })
        try JSONEncoder().encode(seeded).write(to: state)
        let now = Date(timeIntervalSince1970: 1_760_000_100), scanner = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: now), stateURL: state)
        #expect(try await scanner.scanOnce(now: now) == 0)
        let restored = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: now), stateURL: state)
        let codes = await restored.state().recentErrors.map(\.code)
        #expect(codes.count == 200)
        #expect(codes.first == 249)
        #expect(codes.last == 50)
    }

    @Test func streamingRowStopsCursorUntilCompleted() async throws {
        let dir = try halTemp(), db = try fixture(dir), t = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"time":{"created":\#(t),"streamed":\#(t + 500)}}"#, into: db)
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: Date()), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        #expect(await s.state().cursor == 0)
        try db.exec("UPDATE session_message SET data = '{\"model\":{\"id\":\"m\",\"providerID\":\"hal\"},\"time\":{\"created\":\(t),\"completed\":\(t + 1000)}}' WHERE rowid = 1")
        #expect(try await s.scanOnce(now: Date()) == 1)
    }

    @Test func cursorResumesAcrossInstances() async throws {
        let dir = try halTemp(), db = try fixture(dir), t = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        let state = dir.appendingPathComponent("state"), dbPath = dir.appendingPathComponent("opencode.db").path
        let s1 = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: Date()), stateURL: state)
        #expect(try await s1.scanOnce(now: Date()) == 1)
        let s2 = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: Date()), stateURL: state)
        #expect(try await s2.scanOnce(now: Date()) == 0)
    }

    @Test func tableSwitchResetsCursor() async throws {
        // v1 state tracked the frozen `message` table; its cursor is
        // meaningless for session_message ⇒ load must reset (one-off re-backfill).
        let dir = try halTemp(), dbPath = dir.appendingPathComponent("opencode.db").path
        _ = try fixture(dir)
        let state = dir.appendingPathComponent("state")
        // Fully decodable by ScanState (Date as seconds) yet carries no
        // schemaVersion ⇒ only the version gate can reset it.
        let v1JSON = #"{"cursor":9001,"lastScan":"2026-10-13T00:00:00.000Z","recentErrors":[{"code":500,"at":1760000000}]}"#
        try Data(v1JSON.utf8).write(to: state)
        let s = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: Date()), stateURL: state)
        #expect(await s.state().cursor == 0)
        #expect(await s.state().recentErrors.isEmpty)
        let v3JSON = #"{"cursor":9001,"lastScan":"2026-10-13T00:00:00.000Z","recentErrors":[{"code":500,"at":1760000000}],"schemaVersion":3}"#
        try Data(v3JSON.utf8).write(to: state)
        let s3 = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: Date()), stateURL: state)
        #expect(await s3.state().cursor == 0)
        #expect(await s3.state().recentErrors.isEmpty)
    }

    @Test func errorPrivacyCanaryNeverPersisted() async throws {
        // Spec §8: error.message / error.response are never decoded, stored or
        // printed — only type (classification) and status (code) may be read.
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.error","message":"SECRET-CANARY-DO-NOT-STORE upstream blew up","status":500,"response":{"body":"SECRET-CANARY-DO-NOT-STORE","headers":{"x":"SECRET-CANARY-DO-NOT-STORE"}}},"time":{"created":\#(t),"completed":\#(t + 900)}}"#, into: db)
        // A neighboring completed row forces a probe file to exist, so the
        // store-file assertion below has bytes to grep.
        try insert(#"{"model":{"id":"m","providerID":"hal"},"tokens":{"output":50},"time":{"created":\#(t + 2000),"completed":\#(t + 3000)}}"#, into: db)
        let storeDir = dir.appendingPathComponent("store")
        let st = store(storeDir, now: Date())
        let stateURL = dir.appendingPathComponent("state")
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: stateURL)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000)
        #expect(try await s.scanOnce(now: now) == 1)
        // Only the completed neighbor row sampled; the error row never did.
        #expect((await st.probeSamples(provider: .hal, since: .distantPast)).map(\.sessionKey) == ["session_message#2"])
        let state = await s.state()
        #expect(state.recentErrors == [HalErrorRecord(code: 500, at: Date(timeIntervalSince1970: Double(t) / 1000))])
        #expect(!String(decoding: try Data(contentsOf: stateURL), as: UTF8.self).contains("SECRET-CANARY-DO-NOT-STORE"))
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("SECRET-CANARY-DO-NOT-STORE"))
        // No sample ⇒ the store dir may not even exist; if it does, no file may leak.
        if let storeFiles = try? FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil) {
            for url in storeFiles {
                #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("SECRET-CANARY-DO-NOT-STORE"))
            }
        }
    }

    @Test func concurrentScanOnceCannotDuplicateRecords() async throws {
        // The first scan suspends at store.append after committing row 1's
        // cursor; rows 2–4 are the window a concurrent second scan re-reads.
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"tokens":{"output":120},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.error","status":429},"time":{"created":\#(t + 2000)}}"#, into: db)
        try insert(#"{"model":{"id":"m","providerID":"hal"},"error":{"type":"provider.error","status":500},"time":{"created":\#(t + 4000)}}"#, into: db)
        try insert(#"{"model":{"id":"m","providerID":"hal"},"tokens":{"output":60},"time":{"created":\#(t + 6000),"completed":\#(t + 8000)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000)
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: now), stateURL: dir.appendingPathComponent("state"))
        async let first = try s.scanOnce(now: now)
        async let second = try s.scanOnce(now: now)
        let total = try await first + second
        // (b) both calls together count each completable row exactly once.
        #expect(total == 2)
        // (a) the overlap leaves no duplicated error records behind.
        let state = await s.state()
        #expect(state.recentErrors.count == 2)
        #expect(Set(state.recentErrors.map(\.code)) == [429, 500])
        // (c) the winning scan consumed the whole db.
        #expect(state.cursor == 4)
    }

    @Test func secondsMisreadRowsFailDurationGate() async throws {
        let dir = try halTemp(), db = try fixture(dir), t = 1_760_000_000_000
        try insert(#"{"model":{"id":"m","providerID":"hal"},"tokens":{"output":9},"time":{"created":\#(t),"completed":\#(t + 172_800_000)}}"#, into: db)
        let st = store(dir.appendingPathComponent("store"), now: Date())
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 1)
        let sample = await st.probeSamples(provider: .hal, since: .distantPast).first
        #expect(sample?.duration == nil)
        #expect(sample?.tokensPerSecond == nil)
        #expect(sample?.tokens == 9)
    }
}
