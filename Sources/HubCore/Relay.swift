import Foundation

public struct Relay: Sendable {
    public let paths: HubPaths
    public let config: AppConfig
    public let ctlPath: String

    public var push: @Sendable ([String]) -> Bool
    public var openScript: @Sendable (URL) -> Bool
    public var interrupt: @Sendable (Int32) -> Void
    /// Ends a hub-launched session's process (pid, executable name); false if the pid is not that executable.
    public var terminate: @Sendable (Int32, String) -> Bool
    public var usageProvider: @Sendable () -> [String: UsageReading]
    public var recentJobs: @Sendable (String) -> [String]

    public init(paths: HubPaths, config: AppConfig, ctlPath: String,
                push: (@Sendable ([String]) -> Bool)? = nil,
                openScript: (@Sendable (URL) -> Bool)? = nil,
                interrupt: (@Sendable (Int32) -> Void)? = nil,
                terminate: (@Sendable (Int32, String) -> Bool)? = nil,
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
        self.terminate = terminate ?? { pid, exe in
            // Guard against pid reuse: only signal a process that is still the harness executable.
            guard live, pid > 1 else { return false }
            let comm = Proc.run(["ps", "-o", "comm=", "-p", String(pid)]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !comm.isEmpty, URL(fileURLWithPath: comm).lastPathComponent == exe else { return false }
            return kill(pid, SIGTERM) == 0
        }
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
            if let model = model {
                s.model = config.model(model, harness: harness)?.qualifiedID ?? model
            }
            if let pid = pid { s.pid = pid }
            if event == "SessionEnd" { s.status = .ended }
            else if s.status == .ended && event != "SessionStart" && event != "UserPromptSubmit" { }
            else if event == "Stop" || event == "SessionStart" { s.status = .idle }
            else if event == "PermissionRequest" { s.status = .waiting }
            // Claude sends Notification for permission prompts and, after Stop, for idle reminders.
            else if event == "Notification" { if s.status != .idle { s.status = .waiting } }
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

        // A successor launched by a handoff must run the model the handoff asked for (checked before the eligibility guard).
        let mismatch = existing?.model == nil ? model.flatMap { checkSuccessor(harness: harness, sid: sid, model: $0, cwd: effectiveCwd, now: now) } : nil

        guard PolicyEngine.isEligibleSession(config: config, harness: harness, model: effectiveModel, cwd: effectiveCwd) else {
            return nil
        }

        var session = touch(harness, sid, cwd: effectiveCwd, event: event, model: effectiveModel, pid: pid, now: now)

        if let mismatch {
            session = FileStore.withLock(paths, "session-" + sKey) {
                var s = FileStore.read(MainSession.self, from: sFile) ?? session
                s.modelMismatch = mismatch
                try? FileStore.write(s, to: sFile)
                return s
            }
            _ = try? send(harness, sid, "This session was launched by a handoff for \(mismatch). Switch to the expected model before continuing, or tell the user.", kind: .message, now: now)
        }

        if event == "UserPromptSubmit", let prompt = payload["prompt"] as? String, !prompt.isEmpty, !Secrets.contains(prompt) {
            session = FileStore.withLock(paths, "session-" + sKey) {
                var s = FileStore.read(MainSession.self, from: sFile) ?? session
                s.lastPrompt = String(prompt.prefix(600))
                try? FileStore.write(s, to: sFile)
                return s
            }
        }

        // A warned session that ends without handing off leaves an automatic handoff behind.
        if event == "SessionEnd", session.warned != nil, !session.handedOff {
            let file = writeAutoHandoff(session, now: now)
            Activity.log("policy.auto_handoff_file", harness: harness, model: session.model, ["session": String(sid.prefix(8)), "file": file.lastPathComponent], paths: paths, now: now)
        }

        if event == "SessionStart" || event == "SessionEnd" {
            logState(session, event == "SessionEnd" ? .ended : .idle, now: now)
            Activity.log("session.event", harness: harness, model: session.model, ["event": event, "session": String(sid.prefix(8)), "project": URL(fileURLWithPath: session.cwd).lastPathComponent], paths: paths, now: now)
            return nil
        }

        let snapshot = Snapshot(config: config, usage: measuredUsage(now: now), sessions: sessions(now: now), jobs: [], now: now)
        let actions = PolicyEngine.rebalance(snapshot, alreadyWarned: [])
        logState(session, PolicyEngine.state(snapshot, session), now: now)
        noticeResets(snapshot, now: now)

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
                    writeAutoHandoff(session, now: now)
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
                        s.handoffBlocked = nil
                        s.blockedAt = nil
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

    public func handoff(from harness: String, session: String?, project: String, file: String, to modelId: String?, launch: Bool, automatic: Bool,
                        receiver: String? = nil, now: Date) throws -> HandoffRecord {
        // A source re-running the same handoff (agents retry commands) gets the earlier record instead
        // of a second successor that would take another main-session slot.
        if let sid = session, let earlier = recentHandoff(harness, sid, file: file, project: project, now: now) { return earlier }
        do {
            let record = try performHandoff(from: harness, session: session, project: project, file: file, to: modelId, launch: launch,
                                            automatic: automatic, receiver: receiver, now: now)
            if let sid = session { setBlocked(harness, sid, nil, now: now) }
            return record
        } catch {
            Activity.log("policy.handoff_failed", harness: harness, ["from": harness, "to": modelId ?? "auto", "automatic": String(automatic),
                                                                    "reason": String(error.localizedDescription.prefix(200))], paths: paths, now: now)
            if let sid = session { block(harness, sid, reason: error.localizedDescription, now: now) }
            throw error
        }
    }

    static let repeatHandoffWindow: TimeInterval = 600

    private func recentHandoff(_ harness: String, _ sid: String, file: String, project: String, now: Date) -> HandoffRecord? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.handoffs.path) else { return nil }
        let resolved = file.hasPrefix("/") ? file : URL(fileURLWithPath: project).appendingPathComponent(file).path
        let std = { (p: String) in URL(fileURLWithPath: p).standardizedFileURL.path }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { FileStore.read(HandoffRecord.self, from: paths.handoffs.appendingPathComponent($0)) }
            .filter { $0.fromHarness == harness && $0.fromSession == sid && std($0.file) == std(resolved)
                && now.timeIntervalSince($0.created) < Self.repeatHandoffWindow }
            .max { $0.created < $1.created }
    }

    /// Records `handoff_blocked` on the source session once: wrap_up messages are retired (no more
    /// resends or Stop blocks) and a single message names the reason and a fix the user can act on.
    private func block(_ harness: String, _ sid: String, reason: String, now: Date) {
        guard setBlocked(harness, sid, reason, now: now) else { return }
        markDone(harness, sid, kind: .wrapUp, now: now)
        let fix: String
        if reason.contains("Global limit") || reason.contains("maxMainSessions") {
            fix = "close one of the sessions listed, or raise Max main sessions in Agent Hub Settings, then rerun the same handoff command"
        } else if reason.contains("No other main model") || reason.contains("disabled") || reason.contains("not a main model") {
            fix = "enable another main model in Agent Hub Settings or wait for a usage reset, then rerun the same handoff command"
        } else {
            fix = "correct the problem above and rerun the same handoff command"
        }
        _ = try? send(harness, sid, "handoff_blocked: \(reason). Fix: \(fix). Agent Hub will not resend wrap_up for this session.", kind: .message, now: now)
        Activity.log("policy.handoff_blocked", harness: harness, ["session": String(sid.prefix(8)), "reason": String(reason.prefix(200))], paths: paths, now: now)
    }

    /// Sets or clears the blocked state. Returns true when the session was not already blocked.
    @discardableResult
    private func setBlocked(_ harness: String, _ sid: String, _ reason: String?, now: Date) -> Bool {
        FileStore.withLock(paths, "session-" + FileStore.key(harness, sid)) {
            let sFile = paths.sessions.appendingPathComponent("\(FileStore.key(harness, sid)).json")
            guard var s = FileStore.read(MainSession.self, from: sFile) else { return reason != nil }
            let wasBlocked = s.handoffBlocked != nil
            if reason == nil && !wasBlocked { return false }
            s.handoffBlocked = reason
            s.blockedAt = reason == nil ? nil : (s.blockedAt ?? now)
            try? FileStore.write(s, to: sFile)
            return !wasBlocked
        }
    }

    /// The session taking over: explicit, or a session on another harness in the same project that
    /// started after the source was told to wrap up (the user opened it to receive the handoff).
    private func receivingSession(_ active: [MainSession], source: MainSession?, harness: String, project: String, explicit: String?) -> MainSession? {
        if let explicit {
            let parts = explicit.split(separator: ":", maxSplits: 1).map(String.init)
            return active.first { parts.count == 2 ? ($0.harness == parts[0] && $0.sessionId == parts[1]) : $0.sessionId == explicit }
        }
        guard let warned = source?.warned else { return nil }
        let std = { (p: String) in URL(fileURLWithPath: p).standardizedFileURL.path }
        return active.filter { $0.harness != harness && std($0.cwd) == std(project) && $0.started >= warned }
            .max { $0.started < $1.started }
    }

    private func performHandoff(from harness: String, session: String?, project: String, file: String, to modelId: String?, launch: Bool, automatic: Bool,
                                receiver explicitReceiver: String?, now: Date) throws -> HandoffRecord {
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
        let usage = measuredUsage(now: now)
        var activeSessions = sessions(activeOnly: true, now: now)
        var source: MainSession?
        if let sid = session {
            source = activeSessions.first { $0.sessionId == sid && $0.harness == harness }
            activeSessions.removeAll { $0.sessionId == sid && $0.harness == harness }
        } else {
            if let idx = activeSessions.firstIndex(where: { $0.harness == harness }) {
                activeSessions.remove(at: idx)
            }
        }
        // Handoff is one-for-one: the receiving session takes the source's slot instead of needing another.
        let receiver = receivingSession(activeSessions, source: source, harness: harness, project: project, explicit: explicitReceiver)
        if let receiver { activeSessions.removeAll { $0.id == receiver.id } }
        // Sessions on a wrapped-up or exhausted harness are leaving and do not hold a slot.
        let occupying = PolicyEngine.occupying(Snapshot(config: config, usage: usage, sessions: activeSessions, jobs: [], now: now))

        guard occupying.count < config.limits.maxMainSessions else {
            activeSessions = occupying
            let sessionList = activeSessions.map { s in
                let m = s.model ?? "unknown"
                let p = URL(fileURLWithPath: s.cwd).lastPathComponent
                return "\(s.harness)/\(m)@\(p)"
            }.joined(separator: ", ")
            throw HubError.noCapacity("Global limit of \(config.limits.maxMainSessions) main sessions reached (\(activeSessions.count) active: \(sessionList))")
        }

        let snapshot = Snapshot(config: config, usage: usage, sessions: activeSessions, jobs: [], now: now)

        let receiverModel = receiver.flatMap { r in r.model.flatMap { config.model($0, harness: r.harness) } }
        let target: ModelEntry
        if modelId == nil, let receiverModel, receiverModel.isMain, receiverModel.enabled {
            target = receiverModel
        } else if let mId = modelId {
            let m = try config.resolveModel(mId, preferredHarness: harness)
            guard m.isMain && m.enabled else { throw HubError.invalid("Target model is not a main model or is disabled") }
            // Explicit target must honor capacity too
            let check = PolicyEngine.canStartMain(snapshot, m.qualifiedID, harness: m.harness)
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

        let promptText = "Continue the work described in the handoff file \(resolvedFile). Read it first, then continue from 'next steps'. You are now the main model; delegate bounded work with \(Proc.quote(ctlPath)) delegate --main \(target.qualifiedID) --size tiny|routine|hard --kind implement|review|plan --project \(Proc.quote(project)) --objective '<task>' --allowed-file <path> --check '<json argv>' (run \(Proc.quote(ctlPath)) status for capacity)."
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
        let args1 = Proc.fill(targetHarness.withEffort(targetHarness.mainArgs, target), values)
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

        let adopted = receiver.flatMap { r in receiverModel?.qualifiedID == target.qualifiedID ? r : nil }
        if let adopted {
            _ = try? send(adopted.harness, adopted.sessionId, promptText, kind: .task, now: now)
        }

        var launched = false
        if launch && adopted == nil {
            launched = openScript(scriptFile)
            if !launched {
                throw HubError.invalid("Failed to open handoff script")
            }
        }

        var record = HandoffRecord(id: id, fromHarness: harness, fromSession: session, toModel: target.qualifiedID, project: project, file: resolvedFile, script: scriptFile.path, launched: launched, automatic: automatic, created: now)
        record.toSession = adopted?.sessionId
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

        Activity.log("policy.handoff", harness: harness, model: target.qualifiedID, ["from": harness, "to": target.qualifiedID, "automatic": String(automatic)], paths: paths, now: now)
        return record
    }

    /// Closes sessions the hub launched for a handoff (their Terminal window closes with them) once they have
    /// handed off and gone idle, or have been idle for `closeIdleLaunchedSeconds`. Returns log lines.
    public func closeFinished(now: Date) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.handoffs.path) else { return [] }
        var launched = Set<String>()
        for name in names where name.hasSuffix(".json") {
            guard let r = FileStore.read(HandoffRecord.self, from: paths.handoffs.appendingPathComponent(name)),
                  r.launched, let sid = r.successorSession, let h = config.model(r.toModel)?.harness else { continue }
            launched.insert(FileStore.key(h, sid))
        }
        var lines: [String] = []
        for s in sessions(activeOnly: false, now: now) where launched.contains(FileStore.key(s.harness, s.sessionId)) {
            guard s.status == .idle, let pid = s.pid, let exe = config.harness(s.harness)?.executable else { continue }
            let idle = now.timeIntervalSince(s.lastSeen)
            let limit = config.limits.closeIdleLaunchedSeconds
            let reason: String
            if s.handedOff && idle >= 60 { reason = "handed off" }
            else if limit > 0 && idle >= limit { reason = "idle \(Int(idle / 60)) min" }
            else { continue }
            guard terminate(pid, URL(fileURLWithPath: exe).lastPathComponent) else { continue }
            _ = touch(s.harness, s.sessionId, cwd: nil, event: "SessionEnd", model: nil, pid: nil, now: now)
            Activity.log("session.closed", harness: s.harness, model: s.model, ["session": String(s.sessionId.prefix(8)), "reason": reason], paths: paths, now: now)
            lines.append("closed \(s.harness) session \(s.sessionId.prefix(8)) (\(reason))")
        }
        return lines
    }

    /// Matches a new session to the newest unclaimed launched handoff for this harness and project (last 30 min).
    /// Returns "expected <model>, got <model>" when the session runs a different model; logs `session.model_mismatch`.
    func checkSuccessor(harness: String, sid: String, model: String, cwd: String, now: Date) -> String? {
        guard !cwd.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: paths.handoffs.path) else { return nil }
        let project = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let records = names.filter { $0.hasSuffix(".json") }
            .compactMap { FileStore.read(HandoffRecord.self, from: paths.handoffs.appendingPathComponent($0)) }
            .filter { r in
                r.launched && r.toSession == nil && r.successorSession == nil
                    && now.timeIntervalSince(r.created) >= -5 && now.timeIntervalSince(r.created) < 1800
                    && URL(fileURLWithPath: r.project).standardizedFileURL.path == project
                    && config.model(r.toModel)?.harness == harness
            }
            .sorted { $0.created > $1.created }
        guard var record = records.first, let expected = config.model(record.toModel) else { return nil }
        record.successorSession = sid
        record.successorModel = model
        try? FileStore.write(record, to: paths.handoffs.appendingPathComponent("\(record.id).json"))
        // Claude reports variants such as "claude-opus-5-5[1m]"; compare the bare id.
        let actual = String(model.split(separator: "[").first ?? Substring(model))
        let actualID = config.model(actual, harness: harness)?.id ?? URL(fileURLWithPath: actual).lastPathComponent
        guard actualID != expected.id else { return nil }
        Activity.log("session.model_mismatch", harness: harness, model: model,
                     ["expected": expected.qualifiedID, "actual": model, "session": String(sid.prefix(8)), "handoff": record.id], paths: paths, now: now)
        return "expected \(expected.id), got \(model)"
    }

    /// Remembers each harness's band in bands.json. When one recovers from exhausted/wrap-up,
    /// every active main session on another harness gets one "[agent-hub message] <harness> available".
    @discardableResult
    public func noticeResets(_ s: Snapshot, now: Date) -> [String] {
        let file = paths.root.appendingPathComponent("bands.json")
        var recovered: [Harness] = []
        FileStore.withLock(paths, "bands") {
            let before = FileStore.read([String: Int].self, from: file) ?? [:]
            var after = before
            for h in s.config.harnesses {
                let band = PolicyEngine.band(s, h.id)
                after[h.id] = band.rawValue
                if let old = before[h.id], old <= Band.wrapUp.rawValue, band > .wrapUp { recovered.append(h) }
            }
            if after != before { try? FileStore.write(after, to: file) }
        }
        var logs: [String] = []
        for h in recovered {
            let targets = s.sessions.filter { $0.harness != h.id && $0.status != .ended && !$0.handedOff }
            for t in targets {
                _ = try? send(t.harness, t.sessionId, "\(h.name) available — its quota reset; it can take worker jobs again.", kind: .message, now: now)
            }
            Activity.log("policy.reset", harness: h.id, ["notified": String(targets.count)], paths: paths, now: now)
            logs.append("\(h.name) available (notified \(targets.count) session\(targets.count == 1 ? "" : "s"))")
        }
        return logs
    }

    /// Records a session state transition once and logs it as `session.state` for the monitor.
    func logState(_ session: MainSession, _ state: SessionState, now: Date) {
        let key = FileStore.key(session.harness, session.sessionId)
        let changed: MainSession? = FileStore.withLock(paths, "session-" + key) {
            let sFile = paths.sessions.appendingPathComponent("\(key).json")
            guard var s = FileStore.read(MainSession.self, from: sFile), s.lastState != state else { return nil }
            s.lastState = state
            try? FileStore.write(s, to: sFile)
            return s
        }
        guard let s = changed else { return }
        var detail = ["state": state.rawValue, "session": String(s.sessionId.prefix(8)), "project": URL(fileURLWithPath: s.cwd).lastPathComponent]
        if state == .exhausted, let b = s.handoffBlocked { detail["handoff_blocked"] = String(b.prefix(120)) }
        Activity.log("session.state", harness: s.harness, model: s.model, detail, paths: paths, now: now)
    }

    /// Writes (or refreshes) handoffs/auto-<harness>_<sid>.md and records it on the session.
    @discardableResult
    public func writeAutoHandoff(_ session: MainSession, now: Date) -> URL {
        let key = FileStore.key(session.harness, session.sessionId)
        let file = paths.handoffs.appendingPathComponent("auto-\(key).md")
        try? FileManager.default.createDirectory(at: paths.handoffs, withIntermediateDirectories: true)
        try? autoHandoffText(session, now: now).write(to: file, atomically: true, encoding: .utf8)
        FileStore.withLock(paths, "session-" + key) {
            let sFile = paths.sessions.appendingPathComponent("\(key).json")
            if var s = FileStore.read(MainSession.self, from: sFile), s.autoHandoffFile != file.path {
                s.autoHandoffFile = file.path
                try? FileStore.write(s, to: sFile)
            }
        }
        return file
    }

    /// Project files modified since `since`, by mtime; skips VCS, build and dependency folders.
    static func filesChanged(in root: String, since: Date, limit: Int = 50) -> [String] {
        let skip: Set<String> = [".git", ".build", "node_modules", "DerivedData", ".swiftpm", "build", "dist", ".venv"]
        let rootURL = URL(fileURLWithPath: root)
        guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        var found: [(String, Date)] = []
        var scanned = 0
        for case let url as URL in e {
            scanned += 1
            if scanned > 20_000 { break }
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if v?.isDirectory == true {
                if skip.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if let m = v?.contentModificationDate, m >= since {
                let rel = String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
                found.append((rel, m))
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    public func autoHandoffText(_ session: MainSession, now: Date) -> String {
        let stat = Proc.run(["git", "-C", session.cwd, "status", "--short"], timeout: 10)
        let log = Proc.run(["git", "-C", session.cwd, "log", "--oneline", "-5"], timeout: 10)

        var lines = ["Automatic handoff: the previous main model ran out of usage before writing its own handoff."]
        lines.append("Source: \(session.harness) session \(session.sessionId) (\(session.model ?? "unknown model")), project \(session.cwd), started \(ISO8601DateFormatter().string(from: session.started)).")

        let projectJobs = JobStore(paths: paths).all().filter { $0.project == session.cwd }
        lines.append("\n## Last Objective")
        if let p = session.lastPrompt {
            lines.append(p)
        } else if let j = projectJobs.first {
            lines.append("(last delegated job) \(j.objective.prefix(600))")
        } else {
            lines.append("Unknown — check the session transcript.")
        }

        let changed = Self.filesChanged(in: session.cwd, since: session.started)
        lines.append("\n## Files Changed Since Session Start")
        lines.append(changed.isEmpty ? "None found." : changed.map { "- \($0)" }.joined(separator: "\n"))

        lines.append("\n## Last Build/Test Result")
        if let j = projectJobs.first(where: { $0.gate != nil }), let g = j.gate {
            let tail = g.acceptance.output.split(separator: "\n").suffix(5).joined(separator: "\n")
            lines.append("job \(j.id) (\(j.state.rawValue)): `\(g.acceptance.argv.joined(separator: " "))` exit \(g.acceptance.exitCode)\(g.acceptance.timedOut ? " (timed out)" : "") — \(g.acceptance.passed ? "passed" : "failed")")
            if !tail.isEmpty && !Secrets.contains(tail) { lines.append("```\n\(tail)\n```") }
        } else {
            lines.append("No gate result recorded; run the project's build/tests first.")
        }
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
                    writeAutoHandoff(session, now: now)
                    let text = wrapUpText(harness: session.harness, sid: session.sessionId, target: target, reason: reason, cwd: sendCwd)
                    _ = try? send(session.harness, session.sessionId, text, kind: .wrapUp, now: now)
                    Activity.log("policy.wrapup", harness: session.harness, ["to": target?.qualifiedID ?? "none"], paths: paths, now: now)
                    logs.append("wrap-up: \(session.harness) session \(session.sessionId.prefix(8)) → \(target?.name ?? "no target") (\(reason))")
                }
            case .autoHandoff(let session, let target):
                let file = writeAutoHandoff(session, now: now)

                do {
                    let r = try handoff(from: session.harness, session: session.sessionId, project: session.cwd, file: file.path, to: target.qualifiedID, launch: config.autoLaunch, automatic: true, now: now)
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
