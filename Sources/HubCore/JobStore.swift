import Foundation
import CryptoKit

public struct JobStore: Sendable {
    public let paths: HubPaths
    
    public init(paths: HubPaths) {
        self.paths = paths
    }
    
    public static func newId(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dateStr = formatter.string(from: now)
        let hex = String(format: "%06x", Int.random(in: 0...0xFFFFFF))
        return "j-\(dateStr)-\(hex)"
    }
    
    public func save(_ job: Job) throws {
        let url = paths.jobs.appendingPathComponent("\(job.id).json")
        try FileStore.write(job, to: url)
    }
    
    public func get(_ id: String) -> Job? {
        let url = paths.jobs.appendingPathComponent("\(id).json")
        return FileStore.read(Job.self, from: url)
    }
    
    public func all() -> [Job] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: paths.jobs.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { FileStore.read(Job.self, from: paths.jobs.appendingPathComponent($0)) }
            .sorted { $0.created > $1.created }
    }
    
    public func active() -> [Job] {
        return all().filter { $0.state == .queued || $0.state == .running }
    }
    
    /// Validates and stores the job with a fresh id. Returns the stored job.
    @discardableResult
    public func enqueue(_ job: Job, now: Date = Date()) throws -> Job {
        var j = job

        if j.privacy == .generic {
            let o = j.objective
            if o.contains("/Users/") || o.contains("/home/") || o.contains("/private/") || o.contains("/Volumes/") || o.contains("~/") {
                throw HubError.invalid("generic jobs must not contain private paths or emails")
            }
            let emailRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
            let range = NSRange(location: 0, length: o.utf16.count)
            if emailRegex.firstMatch(in: o, options: [], range: range) != nil {
                throw HubError.invalid("generic jobs must not contain private paths or emails")
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: j.project, isDirectory: &isDir), isDir.boolValue else {
            throw HubError.invalid("project must be an existing directory")
        }
        
        guard j.allowedFiles.count >= 1 && j.allowedFiles.count <= 24 else {
            throw HubError.invalid("allowedFiles must have 1-24 items")
        }
        let uniqueFiles = Set(j.allowedFiles)
        guard uniqueFiles.count == j.allowedFiles.count else {
            throw HubError.invalid("allowedFiles must be unique")
        }
        
        for file in j.allowedFiles {
            guard !file.hasPrefix("/") else {
                throw HubError.invalid("allowedFiles cannot contain absolute paths")
            }
            let components = file.components(separatedBy: "/")
            if components.contains("..") {
                throw HubError.invalid("allowedFiles cannot contain ..")
            }
            for comp in components {
                if comp.hasPrefix(".") {
                    throw HubError.invalid("allowedFiles cannot contain hidden components")
                }
                if Secrets.sensitiveNames.contains(comp) {
                    throw HubError.invalid("allowedFiles cannot contain sensitive names")
                }
                if Self.matchesSensitivePattern(comp) {
                    throw HubError.invalid("allowedFiles cannot match sensitive patterns")
                }
            }
        }
        
        guard j.checkArgv.count >= 1 && j.checkArgv.count <= 32 else {
            throw HubError.invalid("checkArgv must have 1-32 strings")
        }
        guard !j.checkArgv.contains(where: { $0.isEmpty }) else {
            throw HubError.invalid("checkArgv cannot contain empty strings")
        }
        
        guard j.objective.count >= 1 && j.objective.count <= 8000 else {
            throw HubError.invalid("objective must be 1-8000 characters")
        }
        
        try Secrets.assertClean([j.objective])
        try Secrets.assertClean(j.allowedFiles)
        try Secrets.assertClean(j.checkArgv)
        
        j.state = .queued
        j.created = now
        // Overwrite ID if needed
        j.id = Self.newId(now: now)
        
        try save(j)
        return j
    }
    
    private static func matchesSensitivePattern(_ name: String) -> Bool {
        let nameLower = name.lowercased()
        if nameLower.hasSuffix(".pem") || nameLower.hasSuffix(".key") { return true }
        if nameLower.hasPrefix("credentials") || nameLower.hasPrefix("token") || nameLower.hasPrefix(".env") || nameLower.hasPrefix("client_secret") { return true }
        return false
    }
}
