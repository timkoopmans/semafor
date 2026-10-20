import Foundation
import Testing
@testable import SemaforCore

private func halTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HalScanner.\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fixture(_ dir: URL) throws -> OpenCodeDb {
    let db = try OpenCodeDb(path: dir.appendingPathComponent("opencode.db").path, readOnly: false)
    try db.exec("CREATE TABLE message (data TEXT NOT NULL)")
    return db
}

private func insert(_ data: String, into db: OpenCodeDb) throws {
    let escaped = data.replacingOccurrences(of: "'", with: "''")
    try db.exec("INSERT INTO message(data) VALUES ('\(escaped)')")
}

private func store(_ dir: URL, now: Date) -> SampleStore {
    SampleStore(config: .init(directory: dir, dateNow: { now }))
}

@Suite("HalScanner")
struct HalScannerTests {
    @Test func emitsSamplesWithSpecFields() async throws {
        let dir = try halTemp(), db = try fixture(dir)
        let t: Int64 = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"hal","modelID":"m","tokens":{"output":180},"time":{"created":\#(t),"completed":\#(t + 2931)}}"#, into: db)
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
        #expect(samples.first?.sessionKey == "opencode.db#1")
        #expect(samples.first?.timestamp == now)
        let stateJSON = String(decoding: try Data(contentsOf: dir.appendingPathComponent("state.json")), as: UTF8.self)
        #expect(stateJSON.contains("\"lastScan\":\""))
        #expect(stateJSON.contains("T") && stateJSON.contains("Z"))
    }

    @Test func nonHalAndNonAssistantIgnoredButConsumed() async throws {
        let dir = try halTemp(), db = try fixture(dir), t = 1_760_000_000_000
        try insert(#"{"role":"user","providerID":"hal","time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        try insert(#"{"role":"assistant","providerID":"other","time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
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
        try insert(#"{"role":"assistant","providerID":"hal","error":{"name":"APIError","data":{"statusCode":400}},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        let st = store(dir.appendingPathComponent("store"), now: Date())
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        let cursor = await s.state().cursor
        #expect(cursor == 1)
        #expect(await st.probeSamples(provider: .hal, since: .distantPast).isEmpty)
    }

    @Test func abortedMessagesInvisible() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"hal","error":{"name":"MessageAbortedError","data":{"message":"Aborted"}},"time":{"created":\#(t)}}"#, into: db)
        let st = store(dir, now: Date()), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        #expect(await st.probeSamples(provider: .hal, since: .distantPast).isEmpty)
        #expect(await s.recentErrors(now: Date(), window: 100_000).isEmpty)
    }

    @Test func apiErrorRecordedNotSampled() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"hal","error":{"name":"APIError","data":{"message":"busy","statusCode":429,"extra":true}},"time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), st = store(dir, now: Date()), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await st.probeSamples(provider: .hal, since: .distantPast).isEmpty)
        let records = await s.recentErrors(now: now, window: 200)
        #expect(records == [HalErrorRecord(code: 429, at: Date(timeIntervalSince1970: Double(t) / 1000))])
    }

    @Test func garbageStatusCodeRecordsZero() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"hal","error":{"name":"APIError","data":{"statusCode":"bad"}},"time":{"created":\#(t)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: now), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await s.recentErrors(now: now, window: 200).first?.code == 0)
    }

    @Test func otherProviderErrorsIgnoredButHalErrorsRecorded() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"other","error":{"name":"APIError","data":{"statusCode":500}},"time":{"created":\#(t)}}"#, into: db)
        try insert(#"{"role":"assistant","providerID":"hal","error":{"name":"APIError","data":{"statusCode":429}},"time":{"created":\#(t + 1000)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: now), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await s.state().cursor == 2)
        #expect(await s.state().recentErrors.map(\.code) == [429])
    }

    @Test func belowThresholdErrorIgnored() async throws {
        let dir = try halTemp(), db = try fixture(dir), t: Int64 = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"hal","error":{"name":"APIError","data":{"statusCode":307}},"time":{"created":\#(t)}}"#, into: db)
        let now = Date(timeIntervalSince1970: Double(t + 100_000) / 1000), s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: now), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: now) == 0)
        #expect(await s.state().cursor == 1)
        #expect(await s.state().recentErrors.isEmpty)
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
        try insert(#"{"role":"assistant","providerID":"hal","time":{"created":\#(t)}}"#, into: db)
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: store(dir, now: Date()), stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 0)
        #expect(await s.state().cursor == 0)
        try db.exec("UPDATE message SET data = '{\"role\":\"assistant\",\"providerID\":\"hal\",\"time\":{\"created\":\(t),\"completed\":\(t + 1000)}}' WHERE rowid = 1")
        #expect(try await s.scanOnce(now: Date()) == 1)
    }

    @Test func cursorResumesAcrossInstances() async throws {
        let dir = try halTemp(), db = try fixture(dir), t = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"hal","time":{"created":\#(t),"completed":\#(t + 1000)}}"#, into: db)
        let state = dir.appendingPathComponent("state"), dbPath = dir.appendingPathComponent("opencode.db").path
        let s1 = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: Date()), stateURL: state)
        #expect(try await s1.scanOnce(now: Date()) == 1)
        let s2 = HalScanner(dbPath: dbPath, settings: AppSettings(), store: store(dir, now: Date()), stateURL: state)
        #expect(try await s2.scanOnce(now: Date()) == 0)
    }

    @Test func secondsMisreadRowsFailDurationGate() async throws {
        let dir = try halTemp(), db = try fixture(dir), t = 1_760_000_000_000
        try insert(#"{"role":"assistant","providerID":"hal","tokens":{"output":9},"time":{"created":\#(t),"completed":\#(t + 172_800_000)}}"#, into: db)
        let st = store(dir.appendingPathComponent("store"), now: Date())
        let s = HalScanner(dbPath: dir.appendingPathComponent("opencode.db").path, settings: AppSettings(), store: st, stateURL: dir.appendingPathComponent("state"))
        #expect(try await s.scanOnce(now: Date()) == 1)
        let sample = await st.probeSamples(provider: .hal, since: .distantPast).first
        #expect(sample?.duration == nil)
        #expect(sample?.tokensPerSecond == nil)
        #expect(sample?.tokens == 9)
    }
}
