Swift package (macOS 14, Swift Testing). Implement the MASKED PIPELINE: a private project job is offloaded to a free untrusted worker (OpenCode) without that worker ever seeing the project. Read Models.swift (Limits.maskedOffloadSizes/brokerMin/MaxIntelligence, Job.offload/broker are already added; do not edit Models.swift), Policy.swift, Runner.swift, Sandbox.swift, JobStore.swift, Secrets.swift, Engine.swift, CLIArgs.swift, Sources/agenthubctl/main.swift first.

1 Policy.swift: add `PolicyEngine.plan(_ s: Snapshot, _ job: Job) -> (worker: ModelEntry, broker: ModelEntry?)?`.
- Masked when job.privacy == .project && job.offload != false && (job.offload == true || limits.maskedOffloadSizes.contains(job.size.rawValue)) && job.kind == .implement: worker = cheapest enabled free isWorker model on an untrusted harness with capacity (same workerCap/maxJobs rules as pickWorker, ignore minIntelligence), broker = pickBroker. If either is nil fall through.
- Otherwise (worker: pickWorker(...), broker: nil).
- `pickBroker(s, mainModel:)`: enabled trusted isWorker model with brokerMinIntelligence...brokerMaxIntelligence, harness band not exhausted/wrapUp and workerCap > 0, prefer a harness other than the main model's, then highest intelligence, then most usage left, then id.

2 New Sources/HubCore/Masked.swift `public enum Masked`:
- `denyTokens(project: String) -> [String]`: project dir basename, path components of project except generic ones (Users, dev, home, private, tmp, var, src, code, projects, Documents), current git branch, NSUserName(), `git config user.email` and user.name; lowercased, length >= 4, unique.
- `scan(dir: URL, tokens: [String]) -> [String]` returns problems for every text file under dir (recursive): contains /Users/, /home/, /Volumes/, /private/, ~/, an email address, Secrets-style key patterns (reuse Secrets.swift if it has a matcher), or any token case-insensitively.
- `maskPrompt(job:maskDir:)`, `decodePrompt(job:maskDir:)` strings (below).

3 Runner.start: when the worker harness is untrusted and job.privacy == .project (replace the current failure for that case):
a. If job.broker is nil or not a trusted model → requeue fallback (below).
b. maskDir = mkdtemp /private/tmp/agenthub-mask-XXXXXX (0700) with files/ subdir; always remove it at the end (defer).
c. MASK: run the broker with its harness workerArgs (account loop + quota cooldown handling like the main loop; extract a helper) with cwd = maskDir and {project} = maskDir. Prompt tells it: read the objective and the allowed files of the real project at <runDir> (read only, never modify it); write maskDir/brief.md = a self-contained generic task where every project name, product, person, company, path, URL, email, key and domain identifier is replaced by neutral placeholders (P1, P2...); write maskDir/files/<flat basename> masked copies of only the files needed (same placeholders); write maskDir/map.json {"placeholders":{"P1":"original"},"files":{"basename":"real relative path"}}; write maskDir/check.json = generic acceptance argv runnable inside files/ (e.g. ["swift","test"] is NOT allowed if it needs the project; prefer a self-contained check such as a small script in files/).
d. Validate: brief.md and files/ exist and non-empty, map.json decodes, every files/ name is a plain basename. tokens = denyTokens(runDir) + map placeholder originals (length >= 4). problems = scan(maskDir/brief.md and maskDir/files). Any problem → fallback. Never pass map.json to the worker.
e. HEAVY: build a synthetic generic Job (objective = brief.md text, allowedFiles = files/ basenames, checkArgv = check.json argv) and run it via Sandbox.prepare(job:runDir: maskDir/files) / Sandbox.wrap / Sandbox.collect into maskDir/files exactly like the existing untrusted path. Then run check argv with cwd maskDir/files (timeout 600). Failure or quota exhaustion → fallback.
f. DECODE: run the broker with cwd = runDir: apply the result in maskDir/files back to the real allowed files of the project, reversing placeholders with map.json, edit only allowed files, run the job's acceptance argv.
g. Normal gate on runDir (existing runGate with before/baseHead taken before DECODE). j.output = short summary of the three steps. j.note = "masked via <broker>".
Fallback: j.state = .queued, j.offload = false, j.harness/model/broker = nil, j.note = "masked offload skipped: <reason>; requeued for a trusted worker", save, return.
Keep the existing generic-job untrusted path unchanged.

4 Engine.swift + agenthubctl main.swift: use PolicyEngine.plan instead of pickWorker; set job.broker = plan.broker?.id (save it) before runner.start. CLI delegate: add `--offload auto|always|never` (auto = nil) in CLIArgs.swift; show worker and broker in --dry-run output.

5 Tests/HubCoreTests/MaskedTests.swift: plan picks masked worker+broker for a hard project job, not for tiny, not with offload=false, nil broker when no tier-3 model; scan flags token/path/email and passes clean text; Runner with a fake exec (Runner.exec is injectable): broker writes brief/files/map/check, fake OpenCode edits staged file, decode writes the real file → job verified; leaked token in brief → job requeued with offload false. Do not call real model CLIs in tests.

Edit only: Policy.swift, Masked.swift, Runner.swift, Engine.swift, CLIArgs.swift, Sources/agenthubctl/main.swift, Tests/HubCoreTests/MaskedTests.swift, Tests/HubCoreTests/CLITests.swift if signatures change. Gate: sh scripts/test.sh passes.
