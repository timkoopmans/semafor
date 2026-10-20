import Foundation
import Testing
@testable import SemaforCore

@Suite struct OpenCodeDbTests {
    private func databasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("opencode.sqlite")
            .path
    }

    private func makeDatabase() throws -> (String, OpenCodeDb) {
        let path = databasePath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try OpenCodeDb(path: path, readOnly: false)
        try db.exec("CREATE TABLE message (id text primary key, session_id text, time_created int, time_updated int, data text)")
        try db.exec("INSERT INTO message (id, data) VALUES ('a', 'first'), ('b', 'second'), ('c', 'third')")
        return (path, db)
    }

    @Test func rowsAreOrderedAndCursorAndLimitAreApplied() throws {
        let (path, db) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }

        let all = try db.rows(after: -1, limit: 10)
        #expect(all.map(\.rowid) == [1, 2, 3])
        #expect(all.map(\.data) == ["first", "second", "third"])
        #expect(try db.rows(after: -1, limit: 2).map(\.rowid) == [1, 2])
        #expect(try db.rows(after: 2, limit: 10).map(\.rowid) == [3])
    }

    @Test func missingPathThrowsOpenFailed() {
        let path = databasePath()
        #expect(throws: OpenCodeDb.DbError.self) {
            try OpenCodeDb(path: path)
        }
    }

    @Test func garbageFileThrowsOpenFailed() throws {
        let path = databasePath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        #expect(throws: OpenCodeDb.DbError.self) {
            try OpenCodeDb(path: path)
        }
    }

    @Test func readOnlyOpenSucceedsAndExecFails() throws {
        let (path, writable) = try makeDatabase()
        defer {
            writable.close()
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        let db = try OpenCodeDb(path: path)
        defer { db.close() }

        #expect(throws: OpenCodeDb.DbError.self) {
            try db.exec("INSERT INTO message (id, data) VALUES ('d', 'fourth')")
        }
    }
}
