import CSQLite
import Foundation

public final class OpenCodeDb: @unchecked Sendable {
    public struct Row: Sendable {
        public let rowid: Int64
        public let data: String
    }

    public enum DbError: Error, Equatable, Sendable {
        case openFailed(status: Int32)
        case queryFailed(status: Int32)
    }

    private var handle: OpaquePointer?
    private let readOnly: Bool

    public init(path: String, readOnly: Bool = true) throws {
        self.readOnly = readOnly
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw DbError.openFailed(status: Int32(status))
        }
        handle = database
        sqlite3_busy_timeout(database, 1000)
        var validation: OpaquePointer?
        let validationStatus = sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master LIMIT 1", -1, &validation, nil)
        if let validation { sqlite3_finalize(validation) }
        guard validationStatus == SQLITE_OK else {
            sqlite3_close(database)
            handle = nil
            throw DbError.openFailed(status: Int32(validationStatus))
        }
    }

    deinit { close() }

    public func rows(after cursor: Int64, limit: Int) throws -> [Row] {
        guard let handle else { throw DbError.queryFailed(status: Int32(SQLITE_MISUSE)) }
        var statement: OpaquePointer?
        let sql = "SELECT rowid, data FROM message WHERE rowid > ? ORDER BY rowid LIMIT ?"
        let prepareStatus = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            throw DbError.queryFailed(status: Int32(prepareStatus))
        }
        defer { sqlite3_finalize(statement) }

        var status = sqlite3_bind_int64(statement, 1, cursor)
        if status == SQLITE_OK { status = sqlite3_bind_int(statement, 2, Int32(clamping: limit)) }
        guard status == SQLITE_OK else { throw DbError.queryFailed(status: Int32(status)) }

        var result: [Row] = []
        while true {
            status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw DbError.queryFailed(status: Int32(status)) }
            let rowid = sqlite3_column_int64(statement, 0)
            // `Row.data` is non-optional, so reject SQL NULL rather than conflating it with empty text.
            guard let text = sqlite3_column_text(statement, 1) else {
                throw DbError.queryFailed(status: Int32(SQLITE_MISMATCH))
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            let data = String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self)
            result.append(Row(rowid: rowid, data: data))
        }
    }

    public func exec(_ sql: String) throws {
        guard !readOnly, let handle else { throw DbError.queryFailed(status: Int32(SQLITE_READONLY)) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        guard status == SQLITE_OK else { throw DbError.queryFailed(status: Int32(status)) }
    }

    public func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }
}
