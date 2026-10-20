import Foundation
import Testing
@testable import SemaforCore

/// Offset tracking, torn-line holding, rotation restart, and state
/// persistence for the session-log tailer (spec §7).
struct SessionLogTailerTests {
    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semafor-tailer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTailer(root: URL, name: String = "tailer-state.json") -> SessionLogTailer {
        SessionLogTailer(stateURL: root.appendingPathComponent(name))
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test func firstCallReadsAllLines_secondCallOnlyAppended() async throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("a.jsonl")
        try write("{\"a\":1}\n{\"a\":2}\n", to: file)
        let tailer = makeTailer(root: root)

        let first = await tailer.pendingLines(in: [logs], namePattern: "*.jsonl")
        #expect(first.map(\.text) == ["{\"a\":1}", "{\"a\":2}"])

        let second = await tailer.pendingLines(in: [logs], namePattern: "*.jsonl")
        #expect(second.isEmpty)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"a\":3}\n".utf8))
        try handle.close()
        let third = await tailer.pendingLines(in: [logs], namePattern: "*.jsonl")
        #expect(third.map(\.text) == ["{\"a\":3}"])
    }

    @Test func tornFinalLineIsHeldUntilComplete() async throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        try write("{\"a\":1}\n{\"trunc", to: file)
        let tailer = makeTailer(root: root)

        let first = await tailer.pendingLines(in: [root], namePattern: "*.jsonl")
        #expect(first.map(\.text) == ["{\"a\":1}"])  // torn fragment not returned

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ated\":2}\n".utf8))
        try handle.close()
        let second = await tailer.pendingLines(in: [root], namePattern: "*.jsonl")
        #expect(second.map(\.text) == ["{\"truncated\":2}"])  // exactly once, complete
    }

    @Test func rotationShrinkRestartsFileAtZero() async throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        try write(String(repeating: "{\"x\":1234567890}\n", count: 5), to: file)
        let tailer = makeTailer(root: root)
        #expect(await tailer.pendingLines(in: [root], namePattern: "*.jsonl").count == 5)

        try write("{\"rotated\":1}\n", to: file)  // same path, smaller file
        let got = await tailer.pendingLines(in: [root], namePattern: "*.jsonl")
        #expect(got.map(\.text) == ["{\"rotated\":1}"])
    }

    @Test func statePersistsAcrossInstances() async throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        try write("{\"a\":1}\n", to: file)

        let first = makeTailer(root: root)
        #expect(await first.pendingLines(in: [root], namePattern: "*.jsonl").count == 1)
        try await first.saveState()

        let second = makeTailer(root: root)
        await second.loadState()
        #expect(await second.pendingLines(in: [root], namePattern: "*.jsonl").isEmpty)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"a\":2}\n".utf8))
        try handle.close()
        #expect(await second.pendingLines(in: [root], namePattern: "*.jsonl").map(\.text)
            == ["{\"a\":2}"])
    }

    @Test func corruptStateToleratedAsEmpty() async throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        try write("{\"a\":1}\n", to: file)
        try Data("this is not json {{{".utf8)
            .write(to: root.appendingPathComponent("tailer-state.json"))

        let tailer = makeTailer(root: root)
        await tailer.loadState()
        #expect(await tailer.pendingLines(in: [root], namePattern: "*.jsonl").count == 1)
    }

    @Test func patternAndNestingHonoured() async throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("proj/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("{\"a\":1}\n", to: nested.appendingPathComponent("s.jsonl"))
        try write("ignored\n", to: nested.appendingPathComponent("notes.txt"))

        let tailer = makeTailer(root: root)
        let got = await tailer.pendingLines(in: [root], namePattern: "*.jsonl")
        #expect(got.count == 1)
        #expect(got[0].url.lastPathComponent == "s.jsonl")
    }

    @Test func pendingLinesSelfLoadsState() async throws {
        // Review I4: the state file must be picked up without an explicit
        // loadState() call, or a scanNow racing start() re-reads everything.
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        try write("{\"a\":1}\n", to: file)
        let first = makeTailer(root: root)
        #expect(await first.pendingLines(in: [root], namePattern: "*.jsonl").count == 1)
        try await first.saveState()

        let second = makeTailer(root: root)  // no explicit loadState()
        #expect(await second.pendingLines(in: [root], namePattern: "*.jsonl").isEmpty)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"a\":2}\n".utf8))
        try handle.close()
        #expect(await second.pendingLines(in: [root], namePattern: "*.jsonl").map(\.text)
            == ["{\"a\":2}"])
    }

    @Test func lastActivityUsesNewestFile() async throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        try write("{\"a\":1}\n", to: file)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        let tailer = makeTailer(root: root)
        let activity = await tailer.lastActivity(of: [root], namePattern: "*.jsonl", now: Date())
        #expect(activity?.timeIntervalSince1970 == 1_700_000_000)

        let missing = await tailer.lastActivity(
            of: [root.appendingPathComponent("nope")], namePattern: "*.jsonl", now: Date())
        #expect(missing == nil)
    }
}
