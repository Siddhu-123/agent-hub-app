import Testing
import Foundation
@testable import HubCore

struct JobLogTests {

    private func makeTempPaths() -> (HubPaths, URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (HubPaths(root: tempDir), tempDir)
    }

    // (1) append twice then tail returns both chunks concatenated
    @Test func appendTwiceThenTailReturnsBothChunksConcatenated() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let id = "test-job-1"

        let chunk1 = Data("hello ".utf8)
        let chunk2 = Data("world\n".utf8)

        JobLog.append(paths, id, chunk1)
        JobLog.append(paths, id, chunk2)

        let result = JobLog.tail(paths, id)
        #expect(result == "hello world\n")
    }

    // (2) mark on a file not ending in newline adds a leading newline, and the marker line is exactly '── text ──'
    @Test func markOnNonNewlineFileAddsLeadingNewlineAndMarkerLineIsExact() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let id = "test-job-mark"

        JobLog.append(paths, id, Data("running job".utf8))
        JobLog.mark(paths, id, "checkpoint")

        let content = JobLog.tail(paths, id)
        #expect(content == "running job\n── checkpoint ──\n")

        // Also verify when already ending in newline
        let id2 = "test-job-mark-newline"
        JobLog.append(paths, id2, Data("running job\n".utf8))
        JobLog.mark(paths, id2, "checkpoint")

        let content2 = JobLog.tail(paths, id2)
        #expect(content2 == "running job\n── checkpoint ──\n")
    }

    // (3) tail strips ANSI escapes like "\u{1B}[31mred\u{1B}[0m" and \r
    @Test func tailStripsAnsiEscapesAndCarriageReturns() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let id = "test-ansi"

        let logContent = "\u{1B}[31mred\u{1B}[0m\r\nline2\r\n"
        JobLog.append(paths, id, Data(logContent.utf8))

        let result = JobLog.tail(paths, id)
        #expect(result == "red\nline2\n")
    }

    // (4) tail with a small maxBytes on a multi-line log starts at a line boundary (no partial first line)
    @Test func tailWithSmallMaxBytesStartsAtLineBoundary() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let id = "test-multiline"

        let logContent = "line 1: first log line\nline 2: second log line\nline 3: third log line\n"
        JobLog.append(paths, id, Data(logContent.utf8))

        // Total length is ~69 bytes. Setting maxBytes to e.g. 35 will fall in the middle of line 2.
        // It should drop the partial line and start after the newline (at line 3).
        let result = JobLog.tail(paths, id, maxBytes: 35)
        #expect(result == "line 3: third log line\n")
    }

    // (5) tail of a missing id returns ""
    @Test func tailOfMissingIdReturnsEmpty() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let result = JobLog.tail(paths, "nonexistent-job")
        #expect(result == "")
    }

    // (6) append with invalid ids ('../x', 'a b', empty, trailing newline) creates no file
    @Test func appendWithInvalidIdsCreatesNoFile() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fm = FileManager.default

        let invalidIds = ["../x", "a b", "", "job-1\n", "job-2\r\n", "\njob-3", "job-4\nextra"]
        for id in invalidIds {
            JobLog.append(paths, id, Data("data".utf8))
            JobLog.mark(paths, id, "mark")
            #expect(JobLog.tail(paths, id) == "")
            let logUrl = JobLog.url(paths, id)
            #expect(!fm.fileExists(atPath: logUrl.path))
        }

        // Also check that the jobs directory itself wasn't even created if all were invalid
        let jobsDir = paths.logs.appendingPathComponent("jobs")
        #expect(!fm.fileExists(atPath: jobsDir.path))
    }

    // (7) the log folder has posix permissions 0o700 and the file 0o600
    @Test func logFolderAndFilePermissions() throws {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let id = "test-perms"

        JobLog.append(paths, id, Data("test permissions\n".utf8))

        let fm = FileManager.default
        let jobsDir = paths.logs.appendingPathComponent("jobs")
        let logUrl = JobLog.url(paths, id)

        let dirAttrs = try fm.attributesOfItem(atPath: jobsDir.path)
        let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(dirPerms == 0o700)

        let fileAttrs = try fm.attributesOfItem(atPath: logUrl.path)
        let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(filePerms == 0o600)
    }

    // (8) prune(keep: 2) with 4 logs whose modification dates are set via FileManager.setAttributes keeps the 2 newest
    @Test func pruneWithFourLogsKeepsTwoNewest() throws {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fm = FileManager.default

        let ids = ["job-1", "job-2", "job-3", "job-4"]
        for id in ids {
            JobLog.append(paths, id, Data("log content for \(id)\n".utf8))
        }

        let now = Date()
        let dates = [
            now.addingTimeInterval(-400),
            now.addingTimeInterval(-300),
            now.addingTimeInterval(-200),
            now.addingTimeInterval(-100)
        ]

        for (i, id) in ids.enumerated() {
            let logUrl = JobLog.url(paths, id)
            try fm.setAttributes([.modificationDate: dates[i]], ofItemAtPath: logUrl.path)
        }

        JobLog.prune(paths, keep: 2)

        #expect(!fm.fileExists(atPath: JobLog.url(paths, "job-1").path))
        #expect(!fm.fileExists(atPath: JobLog.url(paths, "job-2").path))
        #expect(fm.fileExists(atPath: JobLog.url(paths, "job-3").path))
        #expect(fm.fileExists(atPath: JobLog.url(paths, "job-4").path))
    }

    // (9) truncated tail containing no newline returns empty instead of a partial first line
    @Test func truncatedTailWithoutNewlineReturnsEmpty() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let id = "test-no-newline"

        // Log has content and newlines earlier, but the last maxBytes bytes have no newline at all
        let logContent = "header line\n" + String(repeating: "a", count: 50)
        JobLog.append(paths, id, Data(logContent.utf8))

        // maxBytes: 20 falls entirely within the 50 'a's (no newline in the read chunk)
        let result = JobLog.tail(paths, id, maxBytes: 20)
        #expect(result == "")

        // Also test single long line without any newline at all in the file
        let id2 = "test-single-line-no-newline"
        JobLog.append(paths, id2, Data("0123456789abcdefghij".utf8))
        let result2 = JobLog.tail(paths, id2, maxBytes: 10)
        #expect(result2 == "")
    }

    // (10) tail offset already exactly at a line boundary preserves that first full line
    @Test func tailOffsetExactlyAtLineBoundaryPreservesFirstFullLine() {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let id = "test-exact-boundary"

        // "line1\n" is 6 bytes.
        // "line2\n" is 6 bytes.
        // "line3\n" is 6 bytes.
        // Total = 18 bytes.
        let logContent = "line1\nline2\nline3\n"
        JobLog.append(paths, id, Data(logContent.utf8))

        // maxBytes: 12 means offset is 18 - 12 = 6.
        // Byte at index 5 is '\n' from line1!
        // So offset 6 is exactly at the start of line2.
        // It must preserve "line2\nline3\n" and not discard line2.
        let result = JobLog.tail(paths, id, maxBytes: 12)
        #expect(result == "line2\nline3\n")

        // maxBytes: 6 means offset is 18 - 6 = 12.
        // Byte at index 11 is '\n' from line2.
        // Offset 12 is exactly at the start of line3.
        let result2 = JobLog.tail(paths, id, maxBytes: 6)
        #expect(result2 == "line3\n")
    }

    // (11) prune with negative keep does not trap and uses zero retention consistently
    @Test func pruneNegativeKeepUsesZeroRetentionAndPreservesNonLogs() throws {
        let (paths, tempDir) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fm = FileManager.default

        let ids = ["job-a", "job-b"]
        for id in ids {
            JobLog.append(paths, id, Data("content \(id)\n".utf8))
        }

        let jobsDir = paths.logs.appendingPathComponent("jobs")
        let nonLogFile = jobsDir.appendingPathComponent("important.txt")
        let subDir = jobsDir.appendingPathComponent("subdir")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "keep me".write(to: nonLogFile, atomically: true, encoding: .utf8)

        // Pruning with negative keep: should remove all .log files without crashing/trapping
        JobLog.prune(paths, keep: -5)

        #expect(!fm.fileExists(atPath: JobLog.url(paths, "job-a").path))
        #expect(!fm.fileExists(atPath: JobLog.url(paths, "job-b").path))
        // Non-log files and subdirectories must be preserved
        #expect(fm.fileExists(atPath: nonLogFile.path))
        #expect(fm.fileExists(atPath: subDir.path))

        // Same for keep: 0
        JobLog.append(paths, "job-c", Data("content c\n".utf8))
        #expect(fm.fileExists(atPath: JobLog.url(paths, "job-c").path))
        JobLog.prune(paths, keep: 0)
        #expect(!fm.fileExists(atPath: JobLog.url(paths, "job-c").path))
        #expect(fm.fileExists(atPath: nonLogFile.path))
    }
}
