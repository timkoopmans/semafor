import Darwin
import Foundation

/// One newly-read line from a tailed file.
public struct TailedLine: Equatable, Sendable {
    public let url: URL
    public let text: String

    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

/// Byte-offset tailer for CLI session JSONL (spec §7): re-reads only appended
/// bytes, holds torn trailing fragments (offset stays behind them), restarts
/// files that shrank (rotation), and persists offsets so restarts resume.
/// State is advisory — the store's `sessionKey` dedupe is the duplicate guard.
public actor SessionLogTailer {
    private struct TailState: Codable {
        var files: [String: Int] = [:]
    }

    private let stateURL: URL
    private let fileManager = FileManager.default
    private var offsets: [String: Int] = [:]

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    /// Missing or corrupt state is tolerated as empty (a full re-read follows;
    /// dedupe by `sessionKey` on the store's read path covers duplicates).
    public func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(TailState.self, from: data)
        else { return }
        offsets = state.files
    }

    public func saveState() throws {
        let data = try JSONEncoder().encode(TailState(files: offsets))
        try? fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stateURL, options: .atomic)
    }

    /// Appended complete lines for every matching file under `dirs`
    /// (recursive, `namePattern` via fnmatch), sorted by path. Offsets advance
    /// only over the returned lines.
    public func pendingLines(in dirs: [URL], namePattern: String) -> [TailedLine] {
        var result: [TailedLine] = []
        for url in fileURLs(in: dirs, namePattern: namePattern) {
            result.append(contentsOf: pendingLines(for: url))
        }
        return result
    }

    /// Newest content-modification date across matching files; nil when none.
    public func lastActivity(of dirs: [URL], namePattern: String, now: Date) -> Date? {
        var latest: Date?
        for url in fileURLs(in: dirs, namePattern: namePattern) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            if latest == nil || modified > latest! { latest = modified }
        }
        return latest
    }

    // MARK: - File selection

    private func fileURLs(in dirs: [URL], namePattern: String) -> [URL] {
        var urls: [URL] = []
        for dir in dirs {
            guard let enumerator = fileManager.enumerator(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                options: [])
            else { continue }
            for case let url as URL in enumerator {
                guard url.hasDirectoryPath == false else { continue }
                let isMatch: Bool = url.path.withCString { path in
                    namePattern.withCString { pattern in fnmatch(pattern, path, 0) == 0 }
                }
                if isMatch { urls.append(url) }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    // MARK: - Tailing one file

    private func pendingLines(for url: URL) -> [TailedLine] {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return [] }

        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 }  // rotation/truncate: restart
        if size == offset { return [] }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        if offset > 0 {
            do { try handle.seek(toOffset: UInt64(offset)) } catch { return [] }
        }
        guard let data = try? handle.read(upToCount: size - offset), !data.isEmpty else {
            return []
        }

        var lines: [TailedLine] = []
        var consumed = 0
        var lineStart = data.startIndex
        for index in data.indices where data[index] == 0x0A {  // "\n"
            let slice = data[lineStart..<index]
            if !slice.isEmpty {
                lines.append(TailedLine(
                    url: url, text: String(decoding: slice, as: UTF8.self)))
            }
            consumed += (index - lineStart) + 1
            lineStart = data.index(after: index)
        }
        // Fragment after the last "\n" is held: offset advances only over lines.
        offsets[url.path] = offset + consumed
        return lines
    }
}
