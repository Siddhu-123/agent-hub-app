import Foundation

public enum Sandbox {
    static let exe = "/usr/bin/sandbox-exec"
    static let profile = """
        (version 1) (allow default)
        (deny file-read* file-write* (subpath "/Users") (subpath "/Volumes") (subpath "/private/var/folders"))
        (deny network-outbound (remote ip "localhost:*"))
        
        """

    private static let _available: Bool = {
        guard FileManager.default.fileExists(atPath: exe) else { return false }
        return Proc.run([exe, "-p", profile, "/usr/bin/true"], timeout: 5).passed
    }()
    
    public static func available() -> Bool {
        return _available
    }
    
    public struct Stage {
        public var work: URL
        public var dir: URL
        public var env: [String: String]
        public var names: [String: String]
    }
    
    public static func prepare(job: Job, runDir: String, baseEnv: [String: String]) throws -> Stage {
        var names: [String: String] = [:]
        for file in job.allowedFiles {
            let basename = URL(fileURLWithPath: file).lastPathComponent
            if basename.contains("*") || basename.contains("?") || basename.contains("[") {
                throw HubError.invalid("allowedFiles cannot contain glob patterns")
            }
            if names.keys.contains(basename) {
                throw HubError.invalid("allowedFiles basenames must be unique")
            }
            names[basename] = file
        }
        
        var template = Array("/private/tmp/agenthub-XXXXXX".utf8)
        template.append(0)
        guard let ptr = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw HubError.invalid("Failed to create temporary directory")
        }
        let workPath = String(cString: ptr)
        let work = URL(fileURLWithPath: workPath)
        
        chmod(workPath, 0o700)
        
        let dir = work.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        for (basename, file) in names {
            let source = URL(fileURLWithPath: runDir).appendingPathComponent(file).path
            let dest = dir.appendingPathComponent(basename).path
            
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: source, isDirectory: &isDir), !isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: source)
                if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                    continue
                }
                try? FileManager.default.copyItem(atPath: source, toPath: dest)
            }
        }
        
        let configDir = work.appendingPathComponent("config")
        let dataDir = work.appendingPathComponent("data")
        let cacheDir = work.appendingPathComponent("cache")
        let stateDir = work.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        
        var env = baseEnv
        env["XDG_CONFIG_HOME"] = configDir.path
        env["XDG_DATA_HOME"] = dataDir.path
        env["XDG_CACHE_HOME"] = cacheDir.path
        env["XDG_STATE_HOME"] = stateDir.path
        env["TMPDIR"] = work.path
        env["PWD"] = dir.path
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        env["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        env["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
        env["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
        
        var p: [String: String] = ["*": "deny"]
        for basename in names.keys {
            p["\(dir.path)/\(basename)"] = "allow"
            p[basename] = "allow"
        }
        
        let configContent: [String: Any] = [
            "permission": [
                "*": "deny",
                "read": p,
                "edit": p,
                "bash": "deny",
                "external_directory": "deny",
                "task": "deny",
                "skill": "deny",
                "lsp": "deny",
                "webfetch": "deny",
                "websearch": "deny"
            ],
            "share": "disabled",
            "autoupdate": false,
            "formatter": false,
            "lsp": false,
            "mcp": [String: Any]()
        ]
        
        let data = try JSONSerialization.data(withJSONObject: configContent, options: [])
        let configContentStr = String(data: data, encoding: .utf8) ?? ""
        env["OPENCODE_CONFIG_CONTENT"] = configContentStr
        
        let authPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/opencode/auth.json").path
        if let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let authJson = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any],
           let opencodeAuth = authJson["opencode"] {
            let opencodeDir = dataDir.appendingPathComponent("opencode")
            try FileManager.default.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
            let newAuthPath = opencodeDir.appendingPathComponent("auth.json").path
            let newAuthJson = ["opencode": opencodeAuth]
            if let newAuthData = try? JSONSerialization.data(withJSONObject: newAuthJson, options: []) {
                FileManager.default.createFile(atPath: newAuthPath, contents: newAuthData, attributes: [.posixPermissions: 0o600])
            }
        }
        
        return Stage(work: work, dir: dir, env: env, names: names)
    }
    
    /// The tool is resolved to an absolute path first, because the sandboxed process cannot search the user's PATH entries under /Users.
    public static func wrap(_ argv: [String]) -> [String] {
        guard let first = argv.first else { return [exe, "-p", profile] }
        return [exe, "-p", profile, Proc.resolve(first) ?? first] + argv.dropFirst()
    }
    
    public static func collect(_ stage: Stage, into runDir: String) throws -> [String] {
        var copiedPaths: [String] = []
        for (basename, file) in stage.names {
            let stagedFile = stage.dir.appendingPathComponent(basename).path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: stagedFile, isDirectory: &isDir), !isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: stagedFile)
                if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                    continue
                }
                
                let targetFile = URL(fileURLWithPath: runDir).appendingPathComponent(file).path
                let stagedData = try? Data(contentsOf: URL(fileURLWithPath: stagedFile))
                let targetData = try? Data(contentsOf: URL(fileURLWithPath: targetFile))
                
                if stagedData != targetData {
                    let targetURL = URL(fileURLWithPath: targetFile)
                    try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(atPath: targetFile)
                    try? FileManager.default.copyItem(atPath: stagedFile, toPath: targetFile)
                    copiedPaths.append(file)
                }
            }
        }
        return copiedPaths
    }
    
    public static func cleanup(_ stage: Stage) {
        try? FileManager.default.removeItem(at: stage.work)
    }
}
