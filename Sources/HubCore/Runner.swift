import Foundation
import CryptoKit

public final class Runner: @unchecked Sendable {
    public let paths: HubPaths
    private var _config: AppConfig
    /// Replaceable while jobs run (the Engine updates it after a settings change).
    public var config: AppConfig {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }
    
    public typealias Exec = ([String], String?, [String: String]?, String?, TimeInterval, @escaping (Int32) -> Void) -> CheckResult
    public var exec: Exec
    
    private let lock = NSLock()
    private var pids: [String: Int32] = [:]
    
    public init(paths: HubPaths, config: AppConfig) {
        self.paths = paths
        self._config = config
        self.exec = { Proc.run($0, cwd: $1, env: $2, stdin: $3, timeout: $4, onStart: $5) }
    }
    
    public func start(_ job: Job, worker: ModelEntry, now: Date) -> Job {
        let config = self.config
        let store = JobStore(paths: paths)
        var j = job
        // Another process (the app or `agenthubctl delegate --wait`) may have claimed the job already.
        if let current = store.get(j.id), current.state != .queued { return current }
        guard let harness = config.harness(worker.harness) else { return j }
        
        let stdProject = URL(fileURLWithPath: j.project).standardized.path
        let projectData = Data(stdProject.utf8)
        let sha256 = SHA256.hash(data: projectData).map { String(format: "%02x", $0) }.joined()
        let lockName = sha256
        
        try? FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(lockName).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        var lockHeld = false
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockHeld = true
            }
        }
        defer {
            if lockHeld { flock(fd, LOCK_UN) }
            if fd >= 0 { close(fd) }
        }

        if !harness.trusted {
            if j.privacy == .project && j.offload != false && (j.offload == true || config.limits.maskedOffloadSizes.contains(j.size.rawValue)) && j.kind == .implement {
                if let brokerId = j.broker, let brokerModel = config.model(brokerId), let brokerHarness = config.harness(brokerModel.harness), brokerHarness.trusted {
                    var runDir = j.project
                    if !lockHeld {
                        if j.isolation == .worktree {
                            runDir = paths.worktrees.appendingPathComponent(j.id).path
                            try? FileManager.default.createDirectory(at: paths.worktrees, withIntermediateDirectories: true)
                            let res = Proc.run(["git", "-C", j.project, "worktree", "add", runDir, "-b", "agenthub/\(j.id)"])
                            if !res.passed {
                                j.state = .failed
                                j.note = "Worktree creation failed: \(res.output)"
                                try? store.save(j)
                                return j
                            }
                            j.worktree = runDir
                            j.branch = "agenthub/\(j.id)"
                        } else {
                            return j
                        }
                    }
                    return runMasked(job: j, worker: worker, workerHarness: harness, brokerModel: brokerModel, brokerHarness: brokerHarness, now: now, store: store, runDir: runDir)
                } else {
                    return fallbackMasked(job: j, reason: "broker is missing or not trusted", store: store)
                }
            }
            if j.privacy != .generic {
                j.state = .failed
                j.note = "untrusted harness only runs generic jobs"
                try? store.save(j)
                return j
            }
            if !Sandbox.available() {
                j.state = .failed
                j.note = "macOS sandbox unavailable for untrusted harness"
                try? store.save(j)
                return j
            }
        }
        
        var runDir = j.project
        if !lockHeld {
            if j.isolation == .worktree {
                runDir = paths.worktrees.appendingPathComponent(j.id).path
                try? FileManager.default.createDirectory(at: paths.worktrees, withIntermediateDirectories: true)
                let res = Proc.run(["git", "-C", j.project, "worktree", "add", runDir, "-b", "agenthub/\(j.id)"])
                if !res.passed {
                    j.state = .failed
                    j.note = "Worktree creation failed: \(res.output)"
                    try? store.save(j)
                    return j
                }
                j.worktree = runDir
                j.branch = "agenthub/\(j.id)"
            } else {
                return j // Still queued
            }
        }
        
        j.state = .running
        j.harness = worker.harness
        j.model = worker.id
        j.started = now
        try? store.save(j)
        
        var stage: Sandbox.Stage?
        if !harness.trusted {
            do {
                stage = try Sandbox.prepare(job: j, runDir: runDir, baseEnv: ProcessInfo.processInfo.environment)
            } catch {
                j.state = .failed
                j.note = "Sandbox prepare failed: \(error)"
                try? store.save(j)
                return j
            }
        }
        defer { if let stage { Sandbox.cleanup(stage) } }

        let candidates = harness.accounts.isEmpty ? [harness.executable] : harness.accounts
        
        var lastOutput = ""
        var workerExited = false
        var latestCooling = now.addingTimeInterval(1800)
        let before = snapshot(runDir)
        let baseHead = head(runDir)
        
        let role = j.kind.rawValue
        var prompt = "Role: \(role)\nObjective: \(j.objective)\nAllowed files: \(j.allowedFiles.joined(separator: ", "))\nPrivacy class: \(j.privacy.rawValue)\nAcceptance argv: \(j.checkArgv.joined(separator: " "))\nRules: only edit allowed files, do not spawn workers, do not read credentials, run the acceptance argv before finishing."
        if j.privacy == .generic {
            prompt = "Role: \(role)\nObjective: \(j.objective)\nAllowed files: \(j.allowedFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))\nPrivacy class: \(j.privacy.rawValue)\nAcceptance argv (the hub runs it after you finish): \(j.checkArgv.joined(separator: " "))\nRules: only edit allowed files in the current directory; you cannot run shell commands."
        }
        
        for candidate in candidates {
            if !harness.accounts.isEmpty {
                if let _ = Cooldowns.until(account: candidate, paths: paths, now: now) { continue }
            } else {
                if let _ = Cooldowns.until(model: worker.id, paths: paths, now: now) { continue }
            }
            
            var env = stage?.env ?? ProcessInfo.processInfo.environment
            env[HubPaths.workerEnv] = "1"
            
            let stdin = harness.promptViaStdin ? prompt : nil
            let pStr = harness.promptViaStdin ? "-" : prompt
            let values = [
                "exe": candidate,
                "model": worker.id,
                "effort": worker.effort ?? "high",
                "project": stage?.dir.path ?? runDir,
                "prompt": pStr
            ]
            var argv = Proc.fill(harness.workerArgs, values)
            if !harness.trusted { argv = Sandbox.wrap(argv) }
            
            if store.get(j.id)?.state == .cancelled {
                return store.get(j.id) ?? j
            }
            
            let res = exec(argv, stage?.dir.path ?? runDir, env, stdin, config.limits.jobTimeoutSeconds) { pid in
                self.lock.lock()
                self.pids[j.id] = pid
                self.lock.unlock()
            }
            
            self.lock.lock()
            self.pids.removeValue(forKey: j.id)
            self.lock.unlock()
            
            if store.get(j.id)?.state == .cancelled {
                return store.get(j.id) ?? j
            }
            
            lastOutput = res.output
            if let seconds = Cooldowns.fromOutput(res.output, now: now) {
                let coolingUntil = now.addingTimeInterval(seconds)
                latestCooling = coolingUntil
                if !harness.accounts.isEmpty {
                    Cooldowns.set("account:\(candidate)", until: coolingUntil, paths: paths)
                } else {
                    Cooldowns.set("model:\(worker.id)", until: coolingUntil, paths: paths)
                }
                j.attempts.append(JobAttempt(harness: harness.id, model: worker.id, account: candidate, result: "quota", coolingUntil: coolingUntil))
                
                if j.attempts.count >= 3 {
                    j.state = .failed
                    j.output = formatOutput(lastOutput, harness: harness)
                    try? store.save(j)
                    return j
                }
                continue // Try next candidate
            } else {
                workerExited = true
                if res.exitCode != 0 || res.timedOut {
                    j.output = formatOutput(lastOutput, harness: harness) + "\nExit code: \(res.exitCode)"
                } else {
                    j.output = formatOutput(lastOutput, harness: harness)
                }
                break // No quota error, stop trying candidates
            }
        }
        
        if !workerExited {
            // All exhausted
            Cooldowns.set("harness:\(harness.id)", until: latestCooling, paths: paths)
            j.state = .queued
            j.harness = nil
            j.model = nil
            try? store.save(j)
            return j
        }
        
        if let stage {
            do {
                _ = try Sandbox.collect(stage, into: runDir)
            } catch { }
        }
        
        j.gate = runGate(job: j, runDir: runDir, before: before, baseHead: baseHead)
        
        if let g = j.gate {
            if j.kind == .implement {
                j.state = g.passed ? .verified : .needsReview
            } else {
                j.state = (g.acceptance.passed && g.outsideAllowed.isEmpty) ? .verified : .needsReview
            }
        }
        
        j.finished = Date()
        try? store.save(j)
        return j
    }
    
    private func fallbackMasked(job: Job, reason: String, store: JobStore) -> Job {
        var j = job
        j.state = .queued
        j.offload = false
        j.harness = nil
        j.model = nil
        j.broker = nil
        j.note = "masked offload skipped: \(reason); requeued for a trusted worker"
        try? store.save(j)
        return j
    }

    private func runMasked(job: Job, worker: ModelEntry, workerHarness: Harness, brokerModel: ModelEntry, brokerHarness: Harness, now: Date, store: JobStore, runDir: String) -> Job {
        var j = job
        j.state = .running
        j.harness = worker.harness
        j.model = worker.id
        j.started = now
        try? store.save(j)

        let maskDirTemplate = "/private/tmp/agenthub-mask-XXXXXX"
        var template = Array(maskDirTemplate.utf8)
        template.append(0)
        guard let ptr = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            return fallbackMasked(job: j, reason: "Failed to create mask dir", store: store)
        }
        let maskDir = String(cString: ptr)
        chmod(maskDir, 0o700)
        defer { try? FileManager.default.removeItem(atPath: maskDir) }
        
        let filesDir = URL(fileURLWithPath: maskDir).appendingPathComponent("files").path
        try? FileManager.default.createDirectory(atPath: filesDir, withIntermediateDirectories: true, attributes: nil)
        
        // MASK
        let maskPrompt = Masked.maskPrompt(job: j, runDir: runDir, maskDir: maskDir)
        let maskRes = runHelper(j: &j, harness: brokerHarness, worker: brokerModel, prompt: maskPrompt, cwd: maskDir, projectEnv: maskDir, useSandbox: false, now: now, store: store)
        
        if !maskRes.workerExited {
            Cooldowns.set("harness:\(brokerHarness.id)", until: maskRes.latestCooling, paths: paths)
            j.state = .queued
            j.harness = nil
            j.model = nil
            try? store.save(j)
            return j
        }
        if !maskRes.passed {
            return fallbackMasked(job: j, reason: "MASK step failed or exhausted quota: \(maskRes.output)", store: store)
        }
        
        // Validate
        let briefPath = URL(fileURLWithPath: maskDir).appendingPathComponent("brief.md").path
        let mapPath = URL(fileURLWithPath: maskDir).appendingPathComponent("map.json").path
        let checkPath = URL(fileURLWithPath: maskDir).appendingPathComponent("check.json").path
        
        guard let briefText = try? String(contentsOfFile: briefPath, encoding: .utf8), !briefText.isEmpty else {
            return fallbackMasked(job: j, reason: "brief.md missing or empty", store: store)
        }
        
        guard let mapData = try? Data(contentsOf: URL(fileURLWithPath: mapPath)),
              let mapDict = try? JSONSerialization.jsonObject(with: mapData) as? [String: Any],
              let placeholders = mapDict["placeholders"] as? [String: String],
              let _ = mapDict["files"] as? [String: String] else {
            return fallbackMasked(job: j, reason: "map.json failed to decode", store: store)
        }
        
        guard let checkData = try? Data(contentsOf: URL(fileURLWithPath: checkPath)),
              let checkArgv = try? JSONSerialization.jsonObject(with: checkData) as? [String] else {
            return fallbackMasked(job: j, reason: "check.json failed to decode", store: store)
        }
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: filesDir), !files.isEmpty else {
            return fallbackMasked(job: j, reason: "files/ is empty", store: store)
        }
        
        var flatFiles: [String] = []
        for file in files {
            flatFiles.append(file)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: filesDir).appendingPathComponent(file).path, isDirectory: &isDir), isDir.boolValue {
                return fallbackMasked(job: j, reason: "files/ must only contain plain basenames", store: store)
            }
        }
        
        var originalValues = Array(placeholders.values)
        originalValues = originalValues.filter { $0.count >= 4 }
        let tokens = Masked.denyTokens(project: runDir) + originalValues
        
        let problems = Masked.scan(dir: URL(fileURLWithPath: maskDir), tokens: tokens)
        if !problems.isEmpty {
            return fallbackMasked(job: j, reason: "scan detected problems: \(problems.joined(separator: ", "))", store: store)
        }
        
        // The decoder diffs the worker's result against this untouched masked copy.
        let originalDir = URL(fileURLWithPath: maskDir).appendingPathComponent("masked-original").path
        do { try FileManager.default.copyItem(atPath: filesDir, toPath: originalDir) } catch {
            return fallbackMasked(job: j, reason: "could not keep the masked original: \(error)", store: store)
        }

        // HEAVY
        let syntheticJob = Job(id: j.id, project: maskDir, objective: briefText, allowedFiles: flatFiles, checkArgv: checkArgv, size: j.size, kind: j.kind, privacy: .generic, isolation: .checkout, mainModel: nil, created: j.created)
        
        var stage: Sandbox.Stage?
        do {
            stage = try Sandbox.prepare(job: syntheticJob, runDir: filesDir, baseEnv: ProcessInfo.processInfo.environment)
        } catch {
            return fallbackMasked(job: j, reason: "Sandbox.prepare failed: \(error)", store: store)
        }
        defer { if let stage { Sandbox.cleanup(stage) } }
        
        // A free worker gets one more try with the scrubbed check output before the job falls back.
        let basePrompt = Masked.heavyPrompt(brief: briefText, files: flatFiles.sorted())
        var heavyPrompt = basePrompt
        var lastFailure = ""
        var passed = false
        for _ in 0..<max(1, config.limits.maskedHeavyAttempts) {
            let workerRes = runHelper(j: &j, harness: workerHarness, worker: worker, prompt: heavyPrompt, cwd: stage?.dir.path ?? filesDir, projectEnv: stage?.dir.path ?? filesDir, useSandbox: true, now: now, store: store, baseEnv: stage?.env)
            
            if !workerRes.workerExited {
                Cooldowns.set("harness:\(workerHarness.id)", until: workerRes.latestCooling, paths: paths)
                j.state = .queued
                j.harness = nil
                j.model = nil
                try? store.save(j)
                return j
            }
            
            do {
                _ = try Sandbox.collect(stage!, into: filesDir)
            } catch {
                return fallbackMasked(job: j, reason: "Sandbox.collect failed: \(error)", store: store)
            }
            
            // The check may run files the untrusted worker edited, so it runs in the same sandbox.
            var checkEnv = stage?.env ?? ProcessInfo.processInfo.environment
            checkEnv["PWD"] = filesDir
            let checkRes = exec(Sandbox.wrap(checkArgv), filesDir, checkEnv, nil, 600) { pid in
                self.lock.lock()
                self.pids[j.id] = pid
                self.lock.unlock()
            }
            self.lock.lock()
            self.pids.removeValue(forKey: j.id)
            self.lock.unlock()
            
            if checkRes.exitCode == 0 && !checkRes.timedOut { passed = true; break }
            lastFailure = "masked check failed: \(String(checkRes.output.suffix(800)))\nworker output: \(String(workerRes.output.suffix(1500)))"
            heavyPrompt = Masked.retryPrompt(basePrompt, feedback: Masked.feedback(checkRes.output, dirs: [filesDir, maskDir, stage?.dir.path ?? filesDir], tokens: tokens))
        }
        if !passed {
            return fallbackMasked(job: j, reason: lastFailure, store: store)
        }
        
        // DECODE
        let before = snapshot(runDir)
        let baseHead = head(runDir)
        
        let decodePrompt = Masked.decodePrompt(job: j, runDir: runDir, maskDir: maskDir)
        let decodeRes = runHelper(j: &j, harness: brokerHarness, worker: brokerModel, prompt: decodePrompt, cwd: runDir, projectEnv: runDir, useSandbox: false, now: now, store: store)
        
        if !decodeRes.workerExited {
            Cooldowns.set("harness:\(brokerHarness.id)", until: decodeRes.latestCooling, paths: paths)
            j.state = .queued
            j.harness = nil
            j.model = nil
            try? store.save(j)
            return j
        }
        
        // Gate
        j.gate = runGate(job: j, runDir: runDir, before: before, baseHead: baseHead)
        if let g = j.gate {
            if j.kind == .implement {
                j.state = g.passed ? .verified : .needsReview
            } else {
                j.state = (g.acceptance.passed && g.outsideAllowed.isEmpty) ? .verified : .needsReview
            }
        }
        j.finished = Date()
        j.output = "MASK (\(brokerModel.id)): ok\nHEAVY (\(worker.id)): masked check passed\nDECODE (\(brokerModel.id)): \(decodeRes.passed ? "ok" : "exit nonzero")\n\n" + String(decodeRes.output.suffix(2000))
        j.note = "masked via \(brokerModel.id)"
        try? store.save(j)
        return j
    }
    
    private func runHelper(j: inout Job, harness: Harness, worker: ModelEntry, prompt: String, cwd: String, projectEnv: String, useSandbox: Bool, now: Date, store: JobStore, baseEnv: [String: String]? = nil) -> (passed: Bool, workerExited: Bool, latestCooling: Date, output: String) {
        let candidates = harness.accounts.isEmpty ? [harness.executable] : harness.accounts
        var lastOutput = ""
        var workerExited = false
        var latestCooling = now.addingTimeInterval(1800)
        var passed = false
        
        for candidate in candidates {
            if !harness.accounts.isEmpty {
                if let _ = Cooldowns.until(account: candidate, paths: paths, now: now) { continue }
            } else {
                if let _ = Cooldowns.until(model: worker.id, paths: paths, now: now) { continue }
            }
            
            var env = baseEnv ?? ProcessInfo.processInfo.environment
            env[HubPaths.workerEnv] = "1"
            
            let stdin = harness.promptViaStdin ? prompt : nil
            let pStr = harness.promptViaStdin ? "-" : prompt
            let values = [
                "exe": candidate,
                "model": worker.id,
                "effort": worker.effort ?? "high",
                "project": projectEnv,
                "prompt": pStr
            ]
            var argv = Proc.fill(harness.workerArgs, values)
            if useSandbox && !harness.trusted { argv = Sandbox.wrap(argv) }
            
            if store.get(j.id)?.state == .cancelled {
                return (false, true, latestCooling, "")
            }
            
            let jobId = j.id
            let res = exec(argv, cwd, env, stdin, config.limits.jobTimeoutSeconds) { pid in
                self.lock.lock()
                self.pids[jobId] = pid
                self.lock.unlock()
            }
            
            self.lock.lock()
            self.pids.removeValue(forKey: jobId)
            self.lock.unlock()
            
            if store.get(j.id)?.state == .cancelled {
                return (false, true, latestCooling, "")
            }
            
            lastOutput = res.output
            if let seconds = Cooldowns.fromOutput(res.output, now: now) {
                let coolingUntil = now.addingTimeInterval(seconds)
                latestCooling = coolingUntil
                if !harness.accounts.isEmpty {
                    Cooldowns.set("account:\(candidate)", until: coolingUntil, paths: paths)
                } else {
                    Cooldowns.set("model:\(worker.id)", until: coolingUntil, paths: paths)
                }
                j.attempts.append(JobAttempt(harness: harness.id, model: worker.id, account: candidate, result: "quota", coolingUntil: coolingUntil))
                
                if j.attempts.count >= 3 {
                    return (false, true, latestCooling, formatOutput(lastOutput, harness: harness))
                }
                continue // Try next candidate
            } else {
                workerExited = true
                passed = res.exitCode == 0 && !res.timedOut
                if !passed {
                    lastOutput = formatOutput(lastOutput, harness: harness) + "\nExit code: \(res.exitCode)"
                } else {
                    lastOutput = formatOutput(lastOutput, harness: harness)
                }
                break // No quota error, stop trying candidates
            }
        }
        return (passed, workerExited, latestCooling, lastOutput)
    }
    
    private func snapshot(_ runDir: String) -> [String: String] {
        getHashes(status: Proc.run(["git", "status", "--porcelain=v1", "-uall", "-z"], cwd: runDir).output, runDir: runDir)
    }

    /// Changes are measured between the snapshot taken before the worker and one taken right after it,
    /// so files produced by the acceptance command itself are not attributed to the worker.
    private func head(_ runDir: String) -> String? {
        let r = Proc.run(["git", "rev-parse", "HEAD"], cwd: runDir)
        return r.passed ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private func runGate(job: Job, runDir: String, before preHashes: [String: String], baseHead: String?) -> GateResult? {
        let postHashes = snapshot(runDir)
        var changed = Set<String>()
        // Workers in a worktree may commit their work; committed files count as changed too.
        if let baseHead, let postHead = head(runDir), postHead != baseHead {
            let diff = Proc.run(["git", "diff", "--name-only", "-z", baseHead, postHead], cwd: runDir).output
            changed.formUnion(diff.split(separator: "\0").map(String.init).filter { !$0.isEmpty })
        }
        let acceptance = Proc.run(job.checkArgv, cwd: runDir, timeout: 600)

        for f in Set(preHashes.keys).union(postHashes.keys) where preHashes[f] != postHashes[f] {
            changed.insert(f)
        }
        let changedFiles = changed.sorted()
        
        var outsideAllowed: [String] = []
        for f in changedFiles {
            var matched = false
            for pattern in job.allowedFiles {
                if fnmatch(pattern, f, 0) == 0 {
                    matched = true
                    break
                }
            }
            if !matched { outsideAllowed.append(f) }
        }
        
        return GateResult(acceptance: acceptance, changedFiles: changedFiles, outsideAllowed: outsideAllowed)
    }
    
    private func getHashes(status: String, runDir: String) -> [String: String] {
        var hashes: [String: String] = [:]
        let parts = status.components(separatedBy: "\0")
        var i = 0
        while i < parts.count {
            let part = parts[i]
            if part.isEmpty {
                i += 1
                continue
            }
            if part.count >= 4 {
                let state = String(part.prefix(2))
                let file = String(part.dropFirst(3))
                
                var contentHash = "deleted"
                let url = URL(fileURLWithPath: runDir).appendingPathComponent(file)
                if let data = try? Data(contentsOf: url) {
                    contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                hashes[file] = "\(state)|\(contentHash)"
                // Renames and copies carry the original path as the next NUL-separated field.
                if state.hasPrefix("R") || state.hasPrefix("C") { i += 1 }
            }
            i += 1
        }
        return hashes
    }
    
    private func formatOutput(_ output: String, harness: Harness) -> String {
        if harness.id == "codex" {
            let lines = output.components(separatedBy: "\n")
            for line in lines.reversed() {
                if line.contains("\"item.completed\"") && line.contains("\"agent_message\"") {
                    if let data = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = obj["type"] as? String, type == "item.completed",
                       let item = obj["item"] as? [String: Any],
                       let itemType = item["type"] as? String, itemType == "agent_message",
                       let text = item["text"] as? String {
                        return String(text.prefix(4000))
                    }
                }
            }
        }
        if harness.id == "claude" {
            if let data = output.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let res = obj["result"] as? String {
                return String(res.prefix(4000))
            }
        }
        return String(output.suffix(4000))
    }
    
    public func cancel(_ id: String) {
        lock.lock()
        let pid = pids[id]
        lock.unlock()
        
        let store = JobStore(paths: paths)
        if var j = store.get(id) {
            j.state = .cancelled
            try? store.save(j)
        }
        
        guard let pid = pid else { return }
        
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            kill(pid, SIGKILL)
        }
    }
    
    public func mergeWorktree(_ job: Job) throws {
        guard job.state == .verified else {
            throw HubError.invalid("Job is not verified")
        }
        guard let runDir = job.worktree, let branch = job.branch else {
            throw HubError.invalid("Job has no worktree")
        }
        let res = Proc.run(["git", "-C", job.project, "merge", "--no-ff", branch, "-m", "Merge agent-hub job \(job.id)"])
        if !res.passed {
            throw HubError.invalid("Merge failed: \(res.output)")
        }
        _ = Proc.run(["git", "-C", job.project, "worktree", "remove", "--force", runDir])
        _ = Proc.run(["git", "-C", job.project, "branch", "-d", branch])
    }
}
