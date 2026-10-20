import Foundation

/// Append-only JSONL sample ring: one file per record type per day under the
/// app-support directory. Crash-safe (torn final line is skipped, never
/// thrown on), self-rotating by age and size. Never stores credential
/// material — only probe/limit/status records.
public actor SampleStore: LimitsWriting {
    public struct Config: Sendable {
        public var directory: URL
        public var retentionDays: Int
        public var maxBytesPerType: Int
        public var calendar: Calendar
        public var dateNow: @Sendable () -> Date

        public init(
            directory: URL,
            retentionDays: Int = 30,
            maxBytesPerType: Int = 50_000_000,
            calendar: Calendar = SampleStore.utcCalendar,
            dateNow: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.directory = directory
            self.retentionDays = retentionDays
            self.maxBytesPerType = maxBytesPerType
            self.calendar = calendar
            self.dateNow = dateNow
        }
    }

    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let config: Config
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public private(set) var lastReadCorruptLineCount = 0

    public init(config: Config) {
        self.config = config
    }

    public func append(_ record: StoreRecord) async throws {
        let type = Self.type(of: record)
        let now = config.dateNow()
        try fileManager.createDirectory(at: config.directory, withIntermediateDirectories: true)

        var payload = try encoder.encode(record)
        payload.append(contentsOf: [0x0A])  // newline-terminated JSONL
        let url = fileURL(type: type, day: dayString(now))
        if fileManager.fileExists(atPath: url.path) {
            // Existing file: appending via handle can fail (permissions, fd
            // exhaustion) — that must throw, never fall through to the
            // whole-file write below, which would truncate the day's history.
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: url)
        }

        try rotate(type: type, now: now)
    }

    /// Settings "Reset data": wipe the whole store (all days, all types).
    public func deleteAll() async throws {
        if fileManager.fileExists(atPath: config.directory.path) {
            try fileManager.removeItem(at: config.directory)
        }
    }

    public func limits(provider: ProviderID, since: Date) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        var corruptLines = 0
        for url in fileURLs(type: "limits") {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }  // tolerated blank line
                guard let record = try? decoder.decode(StoreRecord.self, from: Data(line.utf8)) else {
                    corruptLines += 1  // e.g. a truncated final line from a crash
                    continue
                }
                if case let .limits(recordProvider, recordWindows, fetchedAt) = record,
                   recordProvider == provider, fetchedAt >= since
                {
                    windows.append(contentsOf: recordWindows)
                }
            }
        }
        lastReadCorruptLineCount = corruptLines
        return windows
    }

    // MARK: - Rotation

    private func rotate(type: String, now: Date) throws {
        let today = config.calendar.startOfDay(for: now)

        for url in fileURLs(type: type) {
            guard let day = day(from: url) else { continue }
            let ageDays = config.calendar.dateComponents([.day], from: day, to: today).day ?? 0
            if ageDays > config.retentionDays {
                try fileManager.removeItem(at: url)
            }
        }

        // Size trim goes oldest-first but never deletes today's in-progress
        // file, even alone-over-cap (the age loop already cannot touch it).
        let survivors = fileURLs(type: type).filter {
            $0.lastPathComponent != "\(type)-\(dayString(now)).jsonl"
        }
        let sizes = try survivors.map { url -> Int in
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? Int) ?? 0
        }
        var total = sizes.reduce(0, +)
        var index = survivors.startIndex
        while total > config.maxBytesPerType, index < survivors.count {
            total -= sizes[index]
            try fileManager.removeItem(at: survivors[index])
            index += 1
        }
    }

    // MARK: - File naming

    private static func type(of record: StoreRecord) -> String {
        switch record {
        case .limits: return "limits"
        }
    }

    private func fileURL(type: String, day: String) -> URL {
        config.directory.appendingPathComponent("\(type)-\(day).jsonl")
    }

    private func fileURLs(type: String) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: config.directory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("\(type)-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }  // date-named ⇒ chronological
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = config.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = config.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func day(from url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let dash = name.firstIndex(of: "-") else { return nil }
        let text = String(name[name.index(after: dash)...])
        let formatter = DateFormatter()
        formatter.calendar = config.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = config.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
