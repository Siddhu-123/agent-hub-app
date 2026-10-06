import Foundation

/// `delegate --split N` / `--fanout`: one project implement job becomes N masked slices, each on a different provider.
public enum Fanout {
    /// Free untrusted workers able to take a masked slice, best per provider.
    public static func providers(_ s: Snapshot, _ job: Job) -> [ModelEntry] {
        let running = s.jobs.filter { $0.state == .running }
        var best: [String: ModelEntry] = [:]
        for m in s.config.models where m.enabled && m.isWorker && m.free {
            guard let h = s.config.harness(m.harness), !h.trusted else { continue }
            guard m.intelligence >= PolicyEngine.minIntelligence(job.size, job.kind, lim: s.config.limits) else { continue }
            guard PolicyEngine.coolingUntil(s, m) == nil else { continue }
            guard running.filter({ $0.harness == m.harness }).count < PolicyEngine.workerCap(s, m.harness) else { continue }
            if let cur = best[m.providerKey], cur.intelligence >= m.intelligence { continue }
            best[m.providerKey] = m
        }
        return best.values.sorted { ($0.intelligence, $1.qualifiedID) > ($1.intelligence, $0.qualifiedID) }
    }

    /// Slices `job` into `n` jobs (n nil = as many as providers and files allow). Throws with a reason instead of degrading silently.
    public static func split(_ s: Snapshot, _ job: Job, n requested: Int?, group: String) throws -> [Job] {
        guard job.privacy == .project, job.kind == .implement else { throw HubError.invalid("--split/--fanout needs a project implement job") }
        guard job.offload != false else { throw HubError.invalid("--split/--fanout always masks; drop --offload never") }
        let workers = providers(s, job)
        let n = requested ?? min(workers.count, job.allowedFiles.count)
        guard n >= 2 else {
            throw HubError.invalid("fan-out needs at least 2 slices; \(workers.count) provider(s) available (\(workers.map(\.qualifiedID).joined(separator: ", "))), \(job.allowedFiles.count) allowed file(s)")
        }
        guard job.allowedFiles.count >= n else { throw HubError.invalid("--split \(n) needs at least \(n) --allowed-file values (got \(job.allowedFiles.count))") }
        guard workers.count >= n else {
            throw HubError.invalid("--split \(n) needs \(n) providers with a free masked worker; available: \(workers.map { "\($0.qualifiedID) [\($0.providerKey)]" }.joined(separator: ", "))")
        }
        guard PolicyEngine.pickBroker(s, mainModel: job.mainModel, mainSession: job.parentSession, explicit: true) != nil else {
            throw HubError.invalid("no trusted broker can mask the slices: \(PolicyEngine.whyQueued(s, job).reason)")
        }
        var buckets = Array(repeating: [String](), count: n)
        for (i, f) in job.allowedFiles.enumerated() { buckets[i % n].append(f) }
        return buckets.enumerated().map { i, files in
            var j = job
            j.allowedFiles = files
            j.offload = true
            j.requestedWorker = workers[i].qualifiedID
            j.splitOf = group
            j.slice = "\(i + 1)/\(n)"
            j.objective = job.objective + "\n\nSlice \(i + 1) of \(n): change only \(files.joined(separator: ", ")); other slices cover the remaining files."
            return j
        }
    }
}

extension Fanout {
    public struct Combined { public var passed: Bool; public var applied: [String]; public var output: String }

    /// A split's check usually needs every slice, so each slice alone fails it. This merges the slices' changed
    /// allowed files from their worktrees into the project checkout and runs the check once. On failure the
    /// checkout is restored. Returns nil when the slices are not ready to combine (a slice is still queued, failed
    /// for another reason, or changed files outside its scope).
    public static func combine(_ slices: [Job], project: String, check: [String],
                               run: ([String], String) -> CheckResult = { Proc.run($0, cwd: $1, timeout: 600) }) -> Combined? {
        guard slices.count >= 2, !check.isEmpty else { return nil }
        var copies: [(from: String, to: String, rel: String)] = []
        for s in slices {
            guard s.state == .verified || s.state == .needsReview, let g = s.gate, g.outsideAllowed.isEmpty, !g.changedFiles.isEmpty else { return nil }
            let dir = s.worktree ?? project
            for rel in g.changedFiles where s.allowedFiles.contains(rel) && dir != project {
                copies.append((dir + "/" + rel, project + "/" + rel, rel))
            }
        }
        let fm = FileManager.default
        var backups: [String: Data?] = [:]
        for c in copies {
            backups[c.to] = fm.contents(atPath: c.to)
            try? fm.createDirectory(atPath: (c.to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: c.to)
            try? fm.copyItem(atPath: c.from, toPath: c.to)
        }
        let res = run(check, project)
        if !res.passed {
            for (path, data) in backups {
                if let data { fm.createFile(atPath: path, contents: data) } else { try? fm.removeItem(atPath: path) }
            }
        }
        return Combined(passed: res.passed, applied: copies.map(\.rel), output: String(res.output.suffix(2000)))
    }
}
