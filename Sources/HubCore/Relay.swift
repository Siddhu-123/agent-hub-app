import Foundation

public struct Relay: Sendable {
    public let paths: HubPaths
    public let config: AppConfig
    public let ctlPath: String

    public var push: @Sendable ([String]) -> Bool
    public var openScript: @Sendable (URL) -> Bool
    public var interrupt: @Sendable (Int32) -> Void
    public var usageProvider: @Sendable () -> [String: UsageReading]
    public var recentJobs: @Sendable (String) -> [String]

    public init(paths: HubPaths, config: AppConfig, ctlPath: String,
                push: (@Sendable ([String]) -> Bool)? = nil,
                openScript: (@Sendable (URL) -> Bool)? = nil,
                interrupt: (@Sendable (Int32) -> Void)? = nil,
                usageProvider: @escaping @Sendable () -> [String: UsageReading] = { [:] },
                recentJobs: @escaping @Sendable (String) -> [String] = { _ in [] }) {
        self.paths = paths
        self.config = config
        self.ctlPath = ctlPath
        // The test gate sets AGENT_HUB_TEST so default side effects never open terminals, message sessions or signal real PIDs.
        let live = ProcessInfo.processInfo.environment["AGENT_HUB_TEST"] == nil
        self.push = push ?? { live && Proc.run($0).passed }
        let termApp = config.terminalApp
        self.openScript = openScript ?? { url in live && Proc.run(["open", "-a", termApp, url.path]).passed }
        self.interrupt = interrupt ?? { pid in if live { kill(pid, SIGINT) } }
        self.usageProvider = usageProvider
        self.recentJobs = recentJobs
    }

    public func touch(_ harness: String, _ sid: String, cwd: String?, event: String, model: String?, pid: Int32?, now: Date) -> MainSession {
        return FileStore.withLock(paths, "session-" + FileStore.key(harness, sid)) {
            let file = paths.sessions.appendingPathComponent("\(FileStore.key(harness, sid)).json")
            var s = FileStore.read(MainSession.self, from: file) ?? MainSession(harness: harness, sessionId: sid, cwd: cwd ?? "", started: now, lastSeen: now, lastEvent: event, status: .working)
            s.lastSeen = now
            s.lastEvent = event
            if let cwd = cwd { s.cwd = cwd }
            if let model = model { s.model = model }
            if let pid = pid { s.pid = pid }
            if event == "SessionEnd" { s.status = .ended }
            else if s.status == .ended && event != "SessionStart" && event != "UserPromptSubmit" { }
            else if event == "Stop" { s.status = .idle }
            else { s.status = .working }
            try? FileStore.write(s, to: file)
            return s
        }
    }

    public func sessions(activeOnly: Bool = true, now: Date) -> [MainSession] {
        let dir = paths.sessions
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var result: [MainSession] = []
        for file in files where file.pathExtension == "json" {
            guard let s = FileStore.read(MainSession.self, from: file) else { continue }
            guard PolicyEngine.isEligibleSession(config: config, harness: s.harness, model: s.model, cwd: s.cwd) else { continue }
            if activeOnly {
                if s.status == .ended || s.handedOff { continue }
                if now.timeIntervalSince(s.lastSeen) > config.limits.activeSeconds { continue }
            }
            result.append(s)
        }
        return result
    }

    public func send(_ harness: String, _ sid: String, _ text: String, kind: MessageKind, now: Date) throws -> InboxMessage {
        try Secrets.assertClean([text])
        return FileStore.withLock(paths, "inbox-" + FileStore.key(harness, sid)) {
            let file = paths.inbox.appendingPathComponent("\(FileStore.key(harness, sid)).json")
            var messages = FileStore.read([InboxMessage].self, from: file) ?? []
            var msg = InboxMessage(kind: kind, text: text, created: now)
            if let h = config.harness(harness), let qa = h.queueArgs {
                let values = ["exe": h.executable, "session": sid, "text": text]
                let argv = Proc.fill(qa, values)
                if push(argv) {
                    msg.pushed = true
                }
            }
            messages.append(msg)
            try? FileStore.write(messages, to: file)
            return msg
        }
    }

    public func pending(_ harness: String, _ sid: String) -> [InboxMessage] {
        let file = paths.inbox.appendingPathComponent("\(FileStore.key(harness, sid)).json")
        let msgs = FileStore.read([InboxMessage].self, from: file) ?? []
        return msgs.filter { $0.done == nil }
    }

    public func markDone(_ harness: String, _ sid: String, kind: MessageKind?, now: Date = Date()) {
        FileStore.withLock(paths, "inbox-" + FileStore.key(harness, sid)) {
            let file = paths.inbox.appendingPathComponent("\(FileStore.key(harness, sid)).json")
            var msgs = FileStore.read([InboxMessage].self, from: file) ?? []
            var changed = false
            for i in 0..<msgs.count {
                if msgs[i].done == nil, (kind == nil || msgs[i].kind == kind) {
                    msgs[i].done = now
                    changed = true
                }
            }
            if changed {
                try? FileStore.write(msgs, to: file)
            }
        }
    }

    private func wrapUpText(harness: String, sid: String, target: ModelEntry?, reason: String, cwd: String) -> String {
        let hName = config.harness(harness)?.name ?? harness
        let cause = reason.contains("global") ? "More than \(config.limits.maxMainSessions) main sessions are open" : "\(hName) usage is low"
        if let target = target {
            return "\(cause), so this session moves to \(target.name). Finish the current step only, write a handoff file (goal, done, in progress, next steps, files touched, gate command), then run: \(Proc.quote(ctlPath)) handoff --from \(harness) --session \(Proc.quote(sid)) --project \(Proc.quote(cwd)) --file <handoff file> and stop."
        } else {
            return "\(cause) and no other main model has capacity; finish the current step, write the handoff file and stop."
        }
    }

    public func hook(_ harness: String, event: String, payload: [String: Any], env: [String: String], now: Date) -> [String: Any]? {
        if env[HubPaths.workerEnv] != nil { return nil }
        guard let sid = (payload["session_id"] ?? payload["thread_id"]) as? String else { return nil }

        let sKey = FileStore.key(harness, sid)
        let sFile = paths.sessions.appendingPathComponent("\(sKey).json")
        let iFile = paths.inbox.appendingPathComponent("\(sKey).json")

        let existing = FileStore.withLock(paths, "session-" + sKey) {
            FileStore.read(MainSession.self, from: sFile)
        }

        let cwd = payload["cwd"] as? String
        let model = payload["model"] as? String
        let pid = (payload["agent_pid"] as? NSNumber)?.int32Value ?? (payload["agent_pid"] as? String).flatMap { Int32($0) }

        let effectiveCwd = cwd ?? existing?.cwd ?? ""
        let effectiveModel = model ?? existing?.model

        guard PolicyEngine.isEligibleSession(config: config, harness: harness, model: effectiveModel, cwd: effectiveCwd) else {
            return nil
        }

        let session = touch(harness, sid, cwd: effectiveCwd, event: event, model: effectiveModel, pid: pid, now: now)

        if event == "SessionStart" || event == "SessionEnd" {
            Activity.log("session.event", harness: harness, model: session.model, ["event": event, "session": String(sid.prefix(8)), "project": URL(fileURLWithPath: session.cwd).lastPathComponent], paths: paths, now: now)
            return nil
        }

        let snapshot = Snapshot(config: config, usage: measuredUsage(now: now), sessions: sessions(now: now), jobs: [], now: now)
        let actions = PolicyEngine.rebalance(snapshot, alreadyWarned: [])

        let wrapUpAction = actions.first(where: {
            if case let .wrapUp(s, _, _) = $0 { return s.id == session.id }
            return false
        })

        if let wrapUpAction {
            if case let .wrapUp(_, target, reason) = wrapUpAction {
                var shouldSend = false
                var sendCwd = session.cwd
                FileStore.withLock(paths, "session-" + sKey) {
                    var s = FileStore.read(MainSession.self, from: sFile) ?? session
                    if s.warned == nil && !s.handedOff && s.status != .ended {
                        s.warned = now
                        try? FileStore.write(s, to: sFile)
                        shouldSend = true
                        sendCwd = s.cwd
                    }
                }
                if shouldSend {
                    let text = wrapUpText(harness: harness, sid: sid, target: target, reason: reason, cwd: sendCwd)
                    _ = try? send(harness, sid, text, kind: .wrapUp, now: now)
                    Activity.log("policy.wrapup", harness: harness, ["to": target?.id ?? "none"], paths: paths, now: now)
                }
            }
        } else {
            var hadWarned = false
            FileStore.withLock(paths, "session-" + sKey) {
                if var s = FileStore.read(MainSession.self, from: sFile) {
                    if s.warned != nil {
                        s.warned = nil
                        try? FileStore.write(s, to: sFile)
                        hadWarned = true
                    }
                }
            }
            if hadWarned {
                FileStore.withLock(paths, "inbox-" + sKey) {
                    var msgs = FileStore.read([InboxMessage].self, from: iFile) ?? []
                    var changed = false
                    for i in 0..<msgs.count where msgs[i].kind == .wrapUp {
                        // Retire delivered ones too, or Stop keeps re-showing a stale wrap-up
                        if msgs[i].done == nil {
                            msgs[i].done = now
                            changed = true
                        }
                    }
                    if changed {
                        try? FileStore.write(msgs, to: iFile)
                    }
                }
            }
        }

        var output: [String: Any]? = nil

        let isHandedOffOrEnded = FileStore.withLock(paths, "session-" + sKey) {
            let s = FileStore.read(MainSession.self, from: sFile)
            return s?.handedOff == true || s?.status == .ended
        }
        guard !isHandedOffOrEnded else { return nil }

        FileStore.withLock(paths, "inbox-" + sKey) {
            var messages = FileStore.read([InboxMessage].self, from: iFile) ?? []
            var toRender: [InboxMessage] = []
            var changed = false

            if event == "UserPromptSubmit" || event == "PostToolUse" {
                for i in 0..<messages.count {
                    if messages[i].done == nil && messages[i].delivered == nil {
                        messages[i].delivered = now
                        toRender.append(messages[i])
                        changed = true
                    }
                }
                if !toRender.isEmpty {
                    output = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": render(toRender)]]
                }
            } else if event == "Stop" {
                for i in 0..<messages.count {
                    if messages[i].done == nil {
                        if messages[i].stopBlocks < config.limits.maxStopBlocks {
                            messages[i].stopBlocks += 1
                            toRender.append(messages[i])
                            changed = true
                        }
                        if messages[i].kind != .wrapUp {
                            messages[i].done = now
                            changed = true
                        }
                    }
                }
                if !toRender.isEmpty {
                    output = ["decision": "block", "reason": render(toRender)]
                }
            }

            if changed {
                try? FileStore.write(messages, to: iFile)
            }
        }

        return output
    }

    private func render(_ messages: [InboxMessage]) -> String {
        var lines = ["Instruction from Agent Hub (the user's orchestrator); act on it once the current request is done:"]
        for m in messages {
            lines.append("[agent-hub \(m.kind.rawValue)] \(m.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func measuredUsage(now: Date) -> [String: UsageReading] {
        let readings = usageProvider()
        Activity.usage(readings, paths: paths, now: now)
        return readings
    }

    public func handoff(from harness: String, session: String?, project: String, file: String, to modelId: String?, launch: Bool, automatic: Bool, now: Date) throws -> HandoffRecord {
        var succeeded = false
        defer {
            if !succeeded { Activity.log("policy.handoff_failed", harness: harness, ["from": harness, "to": modelId ?? "auto", "automatic": String(automatic)], paths: paths, now: now) }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project, isDirectory: &isDir), isDir.boolValue else {
            throw HubError.invalid("Project is not an existing directory")
        }
        let resolvedFile = file.hasPrefix("/") ? file : URL(fileURLWithPath: project).appendingPathComponent(file).path
        guard FileManager.default.fileExists(atPath: resolvedFile) else {
            throw HubError.invalid("Handoff file does not exist")
        }
        let content = try String(contentsOfFile: resolvedFile, encoding: .utf8)
        try Secrets.assertClean([content])

        // Count only eligible active main sessions and allow the source session to leave
        var activeSessions = sessions(activeOnly: true, now: now)
        if let sid = session {
            activeSessions.removeAll { $0.sessionId == sid && $0.harness == harness }
        } else {
            if let idx = activeSessions.firstIndex(where: { $0.harness == harness }) {
                activeSessions.remove(at: idx)
            }
        }

        guard activeSessions.count < config.limits.maxMainSessions else {
            let sessionList = activeSessions.map { s in
                let m = s.model ?? "unknown"
                let p = URL(fileURLWithPath: s.cwd).lastPathComponent
                return "\(s.harness)/\(m)@\(p)"
            }.joined(separator: ", ")
            throw HubError.noCapacity("Global limit of \(config.limits.maxMainSessions) main sessions reached (\(activeSessions.count) active: \(sessionList))")
        }

        let snapshot = Snapshot(config: config, usage: measuredUsage(now: now), sessions: activeSessions, jobs: [], now: now)

        let target: ModelEntry
        if let mId = modelId {
            guard let m = config.model(mId) else { throw HubError.invalid("Target model not found") }
            guard m.isMain && m.enabled else { throw HubError.invalid("Target model is not a main model or is disabled") }
            // Explicit target must honor capacity too
            let check = PolicyEngine.canStartMain(snapshot, m.id)
            guard check.ok else {
                throw HubError.noCapacity(check.reason)
            }
            target = m
        } else {
            guard let best = PolicyEngine.bestMain(snapshot, excludingHarness: harness, planned: [:]) else {
                let candidateHarnesses = config.harnesses.filter { h in
                    h.id != harness && config.models.contains { $0.harness == h.id && $0.enabled && $0.isMain }
                }
                let list = candidateHarnesses.isEmpty ? config.harnesses.filter { $0.id != harness } : candidateHarnesses
                let summary = list.map { "\($0.id): \(PolicyEngine.band(snapshot, $0.id))" }.joined(separator: ", ")
                throw HubError.noCapacity("No other main model has capacity (\(summary))")
            }
            target = best
        }

        guard let targetHarness = config.harness(target.harness) else {
            throw HubError.invalid("Target harness not found")
        }

        let id = UUID().uuidString.lowercased()

        let promptText = "Continue the work described in the handoff file \(resolvedFile). Read it first, then continue from 'next steps'. You are now the main model; delegate bounded work with \(Proc.quote(ctlPath)) delegate --main \(target.id) --size tiny|routine|hard --kind implement|review|plan --project \(Proc.quote(project)) --objective '<task>' --allowed-file <path> --check '<json argv>' (run \(Proc.quote(ctlPath)) status for capacity)."
        let promptFile = paths.handoffs.appendingPathComponent("\(id).prompt.txt")
        try? FileManager.default.createDirectory(at: paths.handoffs, withIntermediateDirectories: true)
        try promptText.write(to: promptFile, atomically: true, encoding: .utf8)

        let exe = Proc.resolve(targetHarness.executable) ?? targetHarness.executable
        let values = [
            "exe": exe,
            "model": target.id,
            "effort": target.effort ?? "high",
            "project": project
        ]
        let args1 = Proc.fill(targetHarness.mainArgs, values)
        let quotedArgs = args1.map { arg -> String in
            if arg.contains("{prompt}") {
                let replaced = arg.replacingOccurrences(of: "{prompt}", with: "$(cat \(Proc.quote(promptFile.path)))")
                return "\"\(replaced)\""
            } else {
                return Proc.quote(arg)
            }
        }.joined(separator: " ")

        let scriptText = "#!/bin/zsh\ncd \(Proc.quote(project))\nexec \(quotedArgs)\n"
        let scriptFile = paths.handoffs.appendingPathComponent("\(id).command")
        try scriptText.write(to: scriptFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptFile.path)

        var launched = false
        if launch {
            launched = openScript(scriptFile)
            if !launched {
                throw HubError.invalid("Failed to open handoff script")
            }
        }

        let record = HandoffRecord(id: id, fromHarness: harness, fromSession: session, toModel: target.id, project: project, file: resolvedFile, script: scriptFile.path, launched: launched, automatic: automatic, created: now)
        try FileStore.write(record, to: paths.handoffs.appendingPathComponent("\(id).json"))

        if let sid = session {
            FileStore.withLock(paths, "session-" + FileStore.key(harness, sid)) {
                let sFile = paths.sessions.appendingPathComponent("\(FileStore.key(harness, sid)).json")
                if var s = FileStore.read(MainSession.self, from: sFile) {
                    s.handedOff = true
                    try? FileStore.write(s, to: sFile)
                }
            }
            markDone(harness, sid, kind: .wrapUp, now: now)

            if automatic, config.limits.interruptOnAutoHandoff {
                let sFile = paths.sessions.appendingPathComponent("\(FileStore.key(harness, sid)).json")
                if let s = FileStore.read(MainSession.self, from: sFile), let pid = s.pid {
                    interrupt(pid)
                }
            }
        }

        succeeded = true
        Activity.log("policy.handoff", harness: harness, model: target.id, ["from": harness, "to": target.id, "automatic": String(automatic)], paths: paths, now: now)
        return record
    }

    public func autoHandoffText(_ session: MainSession, now: Date) -> String {
        let stat = Proc.run(["git", "-C", session.cwd, "status", "--short"], timeout: 10)
        let log = Proc.run(["git", "-C", session.cwd, "log", "--oneline", "-5"], timeout: 10)

        var lines = ["Automatic handoff: the previous main model ran out of usage before writing its own handoff."]
        lines.append("\n## Git Status")
        lines.append(stat.output.isEmpty ? "No changes." : stat.output)
        lines.append("\n## Recent Commits")
        lines.append(log.output.isEmpty ? "None." : log.output)

        let jobs = recentJobs(session.cwd)
        if !jobs.isEmpty {
            lines.append("\n## Recent Jobs")
            lines.append(jobs.joined(separator: "\n"))
        }

        return lines.joined(separator: "\n")
    }

    public func apply(_ actions: [PolicyAction], now: Date) -> [String] {
        var logs: [String] = []
        for action in actions {
            switch action {
            case .wrapUp(let session, let target, let reason):
                let sKey = FileStore.key(session.harness, session.sessionId)
                let sFile = paths.sessions.appendingPathComponent("\(sKey).json")
                var shouldSend = false
                var sendCwd = session.cwd
                FileStore.withLock(paths, "session-" + sKey) {
                    var s = FileStore.read(MainSession.self, from: sFile) ?? session
                    if s.warned == nil && !s.handedOff && s.status != .ended {
                        s.warned = now
                        try? FileStore.write(s, to: sFile)
                        shouldSend = true
                        sendCwd = s.cwd
                    }
                }
                if shouldSend {
                    let text = wrapUpText(harness: session.harness, sid: session.sessionId, target: target, reason: reason, cwd: sendCwd)
                    _ = try? send(session.harness, session.sessionId, text, kind: .wrapUp, now: now)
                    Activity.log("policy.wrapup", harness: session.harness, ["to": target?.id ?? "none"], paths: paths, now: now)
                    logs.append("wrap-up: \(session.harness) session \(session.sessionId.prefix(8)) → \(target?.name ?? "no target") (\(reason))")
                }
            case .autoHandoff(let session, let target):
                let text = autoHandoffText(session, now: now)
                let file = paths.handoffs.appendingPathComponent("auto-\(FileStore.key(session.harness, session.sessionId)).md")
                try? FileManager.default.createDirectory(at: paths.handoffs, withIntermediateDirectories: true)
                try? text.write(to: file, atomically: true, encoding: .utf8)
                
                do {
                    let r = try handoff(from: session.harness, session: session.sessionId, project: session.cwd, file: file.path, to: target.id, launch: config.autoLaunch, automatic: true, now: now)
                    logs.append("handoff: \(session.harness) session \(session.sessionId.prefix(8)) → \(target.name) (automatic\(r.launched ? ", launched" : ""))")
                } catch {
                    logs.append("handoff failed: \(session.harness) session \(session.sessionId.prefix(8)): \(error.localizedDescription)")
                }
            case .notify(let line):
                logs.append(line)
            }
        }
        return logs
    }
}
