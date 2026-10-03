import Foundation

public enum JobLog {
    private static let idRegex = try! NSRegularExpression(pattern: "\\A[A-Za-z0-9._-]{1,80}\\z")

    /// <paths.logs>/jobs/<id>.log
    public static func url(_ paths: HubPaths, _ id: String) -> URL {
        paths.logs.appendingPathComponent("jobs").appendingPathComponent("\(id).log")
    }

    private static func isValidId(_ id: String) -> Bool {
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        return idRegex.firstMatch(in: id, range: range) != nil
    }

    /// Appends raw bytes. Creates the folder (0700) and file (0600). Ignores ids that are not [A-Za-z0-9._-]{1,80}.
    public static func append(_ paths: HubPaths, _ id: String, _ data: Data) {
        guard isValidId(id), !data.isEmpty else { return }
        let logURL = url(paths, id)
        let dirURL = logURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirURL.path) {
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let filePath = logURL.path
        if !fm.fileExists(atPath: filePath) {
            fm.createFile(atPath: filePath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }

    /// Appends "── <text> ──\n" on its own line (adds a leading newline when the file does not end with one).
    public static func mark(_ paths: HubPaths, _ id: String, _ text: String) {
        guard isValidId(id) else { return }
        let logURL = url(paths, id)
        var needsLeadingNewline = false
        if let handle = try? FileHandle(forReadingFrom: logURL) {
            defer { try? handle.close() }
            if let fileSize = try? handle.seekToEnd(), fileSize > 0 {
                do {
                    try handle.seek(toOffset: fileSize - 1)
                    if let lastByte = try handle.read(upToCount: 1), let byte = lastByte.first {
                        if byte != UInt8(ascii: "\n") {
                            needsLeadingNewline = true
                        }
                    }
                } catch { }
            }
        }
        var marker = "── \(text) ──\n"
        if needsLeadingNewline {
            marker = "\n" + marker
        }
        if let data = marker.data(using: .utf8) {
            append(paths, id, data)
        }
    }

    /// Last maxBytes of the log as text: starts at a line boundary, ANSI escape sequences and \r removed. "" when missing.
    public static func tail(_ paths: HubPaths, _ id: String, maxBytes: Int = 16_384) -> String {
        guard isValidId(id) else { return "" }
        let logURL = url(paths, id)
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return "" }
        let readLength = min(Int(fileSize), max(0, maxBytes))
        guard readLength > 0 else { return "" }
        let offset = fileSize - UInt64(readLength)
        do {
            if offset > 0 {
                try handle.seek(toOffset: offset - 1)
                guard let checkByteData = try handle.read(upToCount: 1),
                      let prevByte = checkByteData.first else { return "" }
                guard let data = try handle.read(upToCount: readLength) else { return "" }
                var slice = data
                if prevByte != UInt8(ascii: "\n") {
                    if let firstNewlineIndex = slice.firstIndex(of: UInt8(ascii: "\n")) {
                        slice = slice.subdata(in: (firstNewlineIndex + 1)..<slice.endIndex)
                    } else {
                        return ""
                    }
                }
                let rawString = String(decoding: slice, as: UTF8.self)
                return sanitize(rawString)
            } else {
                try handle.seek(toOffset: 0)
                guard let data = try handle.read(upToCount: readLength) else { return "" }
                let rawString = String(decoding: data, as: UTF8.self)
                return sanitize(rawString)
            }
        } catch {
            return ""
        }
    }

    /// Keeps the newest `keep` logs by modification date and removes the rest.
    public static func prune(_ paths: HubPaths, keep: Int = 200) {
        let dirURL = paths.logs.appendingPathComponent("jobs")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let logFiles = entries.filter { $0.pathExtension == "log" }
        let effectiveKeep = max(0, keep)
        guard logFiles.count > effectiveKeep else { return }

        let sorted = logFiles.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return (url, date)
        }.sorted { $0.1 > $1.1 } // newest first

        for (url, _) in sorted.dropFirst(effectiveKeep) {
            try? fm.removeItem(at: url)
        }
    }

    private static let ansiRegex = try! NSRegularExpression(pattern: #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#)

    private static func sanitize(_ text: String) -> String {
        let withoutCR = text.replacingOccurrences(of: "\r", with: "")
        let range = NSRange(withoutCR.startIndex..<withoutCR.endIndex, in: withoutCR)
        return ansiRegex.stringByReplacingMatches(in: withoutCR, options: [], range: range, withTemplate: "")
    }
}
