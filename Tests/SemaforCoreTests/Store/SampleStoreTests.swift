import Foundation
import Testing

@testable import SemaforCore

private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private func makeStore(
    directory: URL,
    dateNow: @escaping @Sendable () -> Date = { Date() },
    retentionDays: Int = 30,
    maxBytesPerType: Int = 50_000_000
) -> SampleStore {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let config = SampleStore.Config(
        directory: directory,
        retentionDays: retentionDays,
        maxBytesPerType: maxBytesPerType,
        calendar: calendar,
        dateNow: dateNow)
    return SampleStore(config: config)
}

private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SampleStoreTests.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func limitsRecord(_ provider: ProviderID = .claude, _ percent: Double = 42, at date: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> StoreRecord {
    .limits(provider, [
        UsageWindow(name: .fiveHour, usedPercent: percent, windowSeconds: 18_000, resetsAt: date.addingTimeInterval(3600), fetchedAt: date),
    ], fetchedAt: date)
}

@Suite("SampleStore")
struct SampleStoreTests {
    @Test func appendReadRoundTripPreservesFields() async throws {
        let store = makeStore(directory: try tempDirectory())
        let record = limitsRecord(.codex, 61.5)
        try await store.append(record)

        let recovered = await store.limits(provider: .codex, since: .distantPast)
        #expect(recovered.count == 1)
        #expect(recovered[0].name == .fiveHour)
        #expect(recovered[0].usedPercent == 61.5)
        #expect(recovered[0].windowSeconds == 18_000)
        #expect(recovered[0].resetsAt == Date(timeIntervalSince1970: 1_760_000_000 + 3600))
        #expect(recovered[0].fetchedAt == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func sinceFiltersRecords() async throws {
        let dir = try tempDirectory()
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_760_000_000))
        let store = makeStore(directory: dir, dateNow: { dateBox.now })
        let early = limitsRecord(.claude, 10, at: Date(timeIntervalSince1970: 1_760_000_000))
        try await store.append(early)
        let lateDate = Date(timeIntervalSince1970: 1_760_008_640)  // next day
        try await store.append(limitsRecord(.claude, 20, at: lateDate))

        let fromLate = await store.limits(provider: .claude, since: lateDate)
        #expect(fromLate.count == 1)
        #expect(fromLate[0].usedPercent == 20)
    }

    @Test func truncatedFinalLineIsSkippedAndCounted() async throws {
        let dir = try tempDirectory()
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_760_000_000))
        let store = makeStore(directory: dir, dateNow: { dateBox.now })
        try await store.append(limitsRecord(.claude, 10))
        try await store.append(limitsRecord(.claude, 20))

        // Simulate a crash mid-write: append a partial line without newline.
        let dayFile = dir.appendingPathComponent("limits-2025-10-09.jsonl")
        let handle = try FileHandle(forWritingTo: dayFile)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"limits":["claude",[{"nam"#.utf8))
        try handle.close()

        let windows = await store.limits(provider: .claude, since: .distantPast)
        #expect(windows.count == 2)
        #expect(await store.lastReadCorruptLineCount == 1)
    }

    @Test func blankLinesAreTolerated() async throws {
        let dir = try tempDirectory()
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_760_000_000))
        let store = makeStore(directory: dir, dateNow: { dateBox.now })
        try await store.append(limitsRecord(.claude, 10))

        let dayFile = dir.appendingPathComponent("limits-2025-10-09.jsonl")
        let handle = try FileHandle(forWritingTo: dayFile)
        handle.seekToEndOfFile()
        handle.write(Data("\n\n".utf8))
        try handle.close()

        let windows = await store.limits(provider: .claude, since: .distantPast)
        #expect(windows.count == 1)
        #expect(await store.lastReadCorruptLineCount == 0)
    }

    @Test func rotationDeletesFilesOlderThanRetention() async throws {
        let dir = try tempDirectory()
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_760_000_000))
        let store = makeStore(directory: dir, dateNow: { dateBox.now }, retentionDays: 30)
        // Pre-existing file dated 31 days ago.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("limits-2025-09-08.jsonl"))

        try await store.append(limitsRecord(.claude, 10))

        let oldExists = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("limits-2025-09-08.jsonl").path)
        let currentExists = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("limits-2025-10-09.jsonl").path)
        #expect(!oldExists)
        #expect(currentExists)
    }

    @Test func rotationTrimsOldestFilesWhenOverSizeCap() async throws {
        let dir = try tempDirectory()
        let dateBox = DateBox(Date(timeIntervalSince1970: 1_760_000_000))
        let store = makeStore(directory: dir, dateNow: { dateBox.now }, maxBytesPerType: 600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // Backdate three daily files, then append today's record; total size
        // exceeds the cap so the oldest files are trimmed first.
        for dayOffset in [2, 1] {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date(timeIntervalSince1970: 1_760_000_000))!
            let dayString = SampleStoreTests.dayString(day, calendar: calendar)
            try Data(repeating: 0x20, count: 400).write(
                to: dir.appendingPathComponent("limits-\(dayString).jsonl"))
        }

        try await store.append(limitsRecord(.claude, 10))

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files.contains("limits-2025-10-09.jsonl"))
        let oldestDay = calendar.date(byAdding: .day, value: -2, to: Date(timeIntervalSince1970: 1_760_000_000))!
        #expect(!files.contains("limits-\(SampleStoreTests.dayString(oldestDay, calendar: calendar)).jsonl"))
    }

    @Test func concurrentAppendsLeaveAllLinesParseable() async throws {
        let store = makeStore(directory: try tempDirectory())
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    try? await store.append(limitsRecord(.claude, Double(index % 100)))
                }
            }
        }
        let windows = await store.limits(provider: .claude, since: .distantPast)
        #expect(windows.count == 200)
        #expect(await store.lastReadCorruptLineCount == 0)
    }

    @Test func deleteAllRemovesStoreDirectory() async throws {
        let dir = try tempDirectory()
        let store = makeStore(directory: dir)
        try await store.append(limitsRecord(.claude, 10))
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try await store.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func deleteAllOnMissingDirectoryIsNoOp() async throws {
        let store = makeStore(directory: try tempDirectory())
        try await store.deleteAll()  // never appended; must not throw
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
