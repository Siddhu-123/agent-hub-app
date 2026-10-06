import Foundation

public enum Sandbox {
    static let exe = "/usr/bin/sandbox-exec"
    static let profile = """
        (version 1) (allow default)
        (deny file-read* file-write* (subpath "/Users") (subpath "/Volumes") (subpath "/private/var/folders") (regex #"^/private/tmp/agenthub-mask-"))
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
            // Rules are emitted with sorted keys so the "*" fallback comes first; a name sorting before it would be overridden.
            if let c = basename.unicodeScalars.first, c.value <= 0x2A {
                throw HubError.invalid("allowedFiles basenames cannot start with \(c)")
            }
            if names.keys.contains(basename) {
                throw HubError.invalid("allowedFiles basenames must be unique")
            }
            names[basename] = file
        }
        
        var template = Array("/private/tmp/agenthub-XXXXXX".utf8)
        template.append(0)
        let workPath: String? = template.withUnsafeMutableBufferPointer { b in
            mkdtemp(b.baseAddress).map { String(cString: $0) }
        }
        guard let workPath = workPath else {
            throw HubError.invalid("Failed to create temporary directory")
        }
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
        
        var env = scrubbed(baseEnv)
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
        
        // "ask" rather than "deny": denied tools are dropped from the request, which the free tier rejects. Headless runs auto-reject asks.
        var p: [String: String] = ["*": "ask"]
        // OpenCode matches the path in several spellings (it reports /private/tmp paths without the leading slash).
        let real = dir.resolvingSymlinksInPath().path
        let roots = Set([dir.path, real, real.hasPrefix("/private/") ? String(real.dropFirst("/private".count)) : real])
        for basename in names.keys {
            for root in roots {
                p["\(root)/\(basename)"] = "allow"
                p["\(root.dropFirst())/\(basename)"] = "allow"
            }
            p[basename] = "allow"
        }
        
        let configContent: [String: Any] = [
            "permission": [
                "*": "ask",
                "read": p,
                "edit": p,
                // Shell commands run inside the sandbox-exec fence, which only exposes this stage.
                "bash": "allow",
                "external_directory": "ask",
                "task": "ask",
                "skill": "ask",
                "lsp": "ask",
                "webfetch": "ask",
                "websearch": "ask"
            ],
            "share": "disabled",
            "autoupdate": false,
            "formatter": false,
            "lsp": false,
            "mcp": [String: Any]()
        ]
        
        // OpenCode applies rules in order and the last match wins, so "*" must precede the per-file allows; it sorts first.
        let data = try JSONSerialization.data(withJSONObject: configContent, options: [.sortedKeys])
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
    /// With `own` (a stage's work dir) the process is fenced to it: every other temp dir, including other jobs' stages, is denied.
    public static func wrap(_ argv: [String], own: String? = nil) -> [String] {
        let p = own.map(fenced) ?? profile
        guard let first = argv.first else { return [exe, "-p", p] }
        return [exe, "-p", p, Proc.resolve(first) ?? first] + argv.dropFirst()
    }

    static func fenced(_ own: String) -> String {
        // realpath keeps the /private prefix that the profile rules use; URL.resolvingSymlinksInPath strips it.
        let dir = (realpath(own, nil).map { p in defer { free(p) }; return String(cString: p) } ?? own).replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        return """
            (version 1) (allow default)
            (deny file-read* file-write* (subpath "/Users") (subpath "/Volumes") (subpath "/private/var/folders") (subpath "/private/tmp") (subpath "/private/var/tmp"))
            (allow file-read* file-write* (subpath "\(dir)"))
            (deny network-outbound (remote ip "localhost:*"))

            """
    }
    
    static func scrubbed(_ env: [String: String]) -> [String: String] {
        let blockedSubstrings = [
            "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL",
            "API_KEY", "APIKEY", "PRIVATE_KEY", "ACCESS_KEY", "SESSION_KEY"
        ]
        let blockedPrefixes = [
            "AWS_", "GH_", "GITHUB_", "ANTHROPIC_", "OPENAI_", "GEMINI_", "GOOGLE_API"
        ]
        
        return env.filter { key, _ in
            let upper = key.uppercased()
            if blockedSubstrings.contains(where: { upper.contains($0) }) {
                return false
            }
            if upper.hasSuffix("_KEY") {
                return false
            }
            if blockedPrefixes.contains(where: { upper.hasPrefix($0) }) {
                return false
            }
            return true
        }
    }
    
    public static func collect(_ stage: Stage, into runDir: String) throws -> [String] {
        var copiedPaths: [String] = []
        let resolvedRunDir = URL(fileURLWithPath: runDir).resolvingSymlinksInPath().standardized.path
        
        for (basename, file) in stage.names {
            let stagedFile = stage.dir.appendingPathComponent(basename).path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: stagedFile, isDirectory: &isDir), !isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: stagedFile)
                if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                    continue
                }
                
                let targetURL = URL(fileURLWithPath: runDir).appendingPathComponent(file).standardized
                let targetFile = targetURL.path
                
                let targetParentURL = targetURL.deletingLastPathComponent()
                var ancestorURL = targetParentURL
                while !FileManager.default.fileExists(atPath: ancestorURL.path) && ancestorURL.path != "/" {
                    ancestorURL = ancestorURL.deletingLastPathComponent()
                }
                guard FileManager.default.fileExists(atPath: ancestorURL.path) else {
                    continue
                }
                let resolvedAncestor = ancestorURL.resolvingSymlinksInPath().standardized.path
                let parentPrefix = resolvedRunDir.hasSuffix("/") ? resolvedRunDir : resolvedRunDir + "/"
                guard resolvedAncestor == resolvedRunDir || resolvedAncestor.hasPrefix(parentPrefix) else {
                    continue
                }
                
                // Skip if the target itself is a symlink
                if let targetAttrs = try? FileManager.default.attributesOfItem(atPath: targetFile),
                   let targetType = targetAttrs[.type] as? FileAttributeType,
                   targetType == .typeSymbolicLink {
                    continue
                }
                
                let stagedData = try Data(contentsOf: URL(fileURLWithPath: stagedFile))
                let targetData = try? Data(contentsOf: URL(fileURLWithPath: targetFile))
                
                if stagedData != targetData {
                    try FileManager.default.createDirectory(at: targetParentURL, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: targetFile) {
                        try FileManager.default.removeItem(atPath: targetFile)
                    }
                    try FileManager.default.copyItem(atPath: stagedFile, toPath: targetFile)
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
