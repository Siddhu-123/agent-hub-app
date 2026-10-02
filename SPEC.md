# Agent Hub for macOS — build spec

A native SwiftUI app (menu bar + window) plus a bundled CLI, `agenthubctl`. Together they orchestrate AI coding CLIs (Claude Code, Codex, Antigravity, OpenCode or any user-defined harness):

- one or more **main sessions** (frontier models the user talks to);
- bounded **worker jobs** that the mains delegate to smaller or other-harness models;
- usage-aware **policy** that scales sessions and jobs down as quota runs out and **moves** sessions to another harness before they die.

Everything is pure Swift; there are no third-party dependencies and no Python. The app is not sandboxed: it spawns CLIs, writes hook config and opens Terminal.

## 0. Rules for every worker

- Files the orchestrator owns are read-only for you: `Package.swift`, `Sources/HubCore/{Models,Paths,Proc,Secrets}.swift` and this SPEC. Use their types and helpers. Never redefine them.
- Edit only the files your assignment lists.
- Use Swift 5 language mode, Foundation only in HubCore, and macOS 14. Use no third-party packages.
- Use Swift Testing (`import Testing`, `@Test`, `#expect`), never XCTest.
  - Tests must be hermetic: use `HubPaths(root: <temp dir>)`, never the real home folders, never the network, never real AI CLIs.
  - Inject time as `now: Date` parameters, and inject process launching via closures where needed.
- Gate: `sh scripts/test.sh <YourSuite>` must pass. It builds everything first.
- Persisted JSON: `FileStore.write/read` (atomic, ISO-8601). Serialize read-modify-write with `FileStore.withLock(paths, name)`.
- Before any text is sent to a model, a session or a file another model reads, call `Secrets.assertClean`.
- Keep it compact and readable. Add no speculative features.

## 1. Config — `Sources/HubCore/Config.swift`

`public enum ConfigStore`:

**`static func defaults() -> AppConfig`.** The defaults must work for anyone.

Harnesses:

| id | executable | trusted | usageSource | hookStyle | other |
|---|---|---|---|---|---|
| `claude` | `claude` | yes | `claudeStatusline` | `claude` | |
| `codex` | `codex` | yes | `codexSessions` | `codex` | `promptViaStdin` true |
| `antigravity` | `agy` | yes | `manual` | `none` | |
| `opencode` | `opencode` | **no** | `none` | `none` | gets generic-privacy jobs only |

Argument templates:

| harness | mainArgs | workerArgs | queueArgs |
|---|---|---|---|
| `claude` | `["{exe}","--model","{model}","{prompt}"]` | `["{exe}","-p","--model","{model}","--permission-mode","acceptEdits","--output-format","json","{prompt}"]` | — |
| `codex` | `["{exe}","-C","{project}","-m","{model}","-c","model_reasoning_effort={effort}","{prompt}"]` | `["{exe}","exec","--model","{model}","--config","model_reasoning_effort={effort}","--sandbox","workspace-write","--cd","{project}","--skip-git-repo-check","--json","-"]` | `["{exe}","queue","--thread","{session}","--message","{text}"]` |
| `antigravity` | `["{exe}","--model","{model}","-i","{prompt}"]` | `["{exe}","--model","{model}","--dangerously-skip-permissions","--print-timeout","600s","-p","{prompt}"]` | — |
| `opencode` | — | `["{exe}","run","--model","{model}","{prompt}"]` | — |

Models (`id` / harness / intelligence / main / worker / free / effort):

| id | harness | intelligence | main | worker | free | effort |
|---|---|---|---|---|---|---|
| `claude-opus-5-5` | claude | 98 | ✓ | ✗ | | |
| `gpt-6.1-sol` | codex | 97 | ✓ | ✓ | | xhigh |
| `claude-sonnet-5-5` | claude | 88 | ✗ | ✓ | | |
| `gpt-6-sol` | codex | 90 | ✗ | ✓ | | high |
| `gpt-6-luna` | codex | 80 | ✗ | ✓ | | high |
| `claude-haiku-4-5-20251001` | claude | 60 | ✗ | ✓ | | |
| `gemini-3.1-pro-high` | antigravity | 85 | ✗ | ✓ | | |
| `gemini-3.8-flash-high` | antigravity | 72 | ✗ | ✓ | | |
| `gemini-3.8-flash-low` | antigravity | 55 | ✗ | ✓ | | |
| `opencode/big-pickle` | opencode | 50 | ✗ | ✓ | ✓ | |

`mainOrder` is `["claude-opus-5-5","gpt-6.1-sol"]`.

**`static func load(_ paths: HubPaths) -> (config: AppConfig, warning: String?)`.**
- If there is no file, it returns the defaults and writes them.
- If the file is undecodable, it copies it to `config.invalid-<unix>.json`, returns the defaults, and returns a warning.
- It runs `validate` on the result.

**`static func save(_ c: AppConfig, _ paths: HubPaths) throws`** validates first.

**`static func validate(_ c: AppConfig) throws`** throws `HubError.invalid` with a human message when:
- ids are not unique;
- a model references an unknown harness;
- a `mainOrder` id is missing or is not a main model;
- `maxMainSessions` is outside 1...12, or `maxJobs` is outside 0...16;
- thresholds are not ordered as `0 ≤ exhaustedAtOrBelow < wrapUpBelow ≤ singleSessionBelow ≤ sameHarnessMinLeft ≤ 1`;
- an intelligence value is outside 0...100.

**`static func addMainModel(_ c: inout AppConfig, model: ModelEntry)`** adds the model (or updates it with `isMain = true`) and appends it to `mainOrder`. This is how a user adds a future model, for example Gemini 4, as a main model.

## 2. Usage — `Sources/HubCore/Usage.swift`

`public struct UsageMeter { let paths: HubPaths; var codexSessionsDir: URL = ~/.codex/sessions }`

**`func read(_ c: AppConfig, now: Date) -> [String: UsageReading]`** returns one reading per harness id.

Per `usageSource`:
- **`codexSessions`:**
  - Take the 5 newest `*.jsonl` files found recursively under `codexSessionsDir`, by modification time.
  - For each, read the last 400 kB and find the last occurrence of `"rate_limits":`. Decode the JSON object that follows; use `JSONSerialization` on a balanced-brace scan.
  - Its shape is `{"primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1790963171},"secondary":{...}}`, with `resets_at` in unix seconds.
  - Windows: primary is `5h` and secondary is `7d`.
  - A window whose `resetsAt <= now` counts as 0% used.
  - `asOf` is the file's modification date.
- **`claudeStatusline`:** read `paths.claudeUsage`, shaped as `{"five_hour":{"used_percentage":12,"resets_at":<unix>},"seven_day":{...},"as_of":<unix>}`. Windows are `5h` and `7d`, with the same reset rule.
- **`manual`:** use `harness.manualLeft`.
- **`none`:** nil (unknown).

`left = min over windows of (1 - used/100)`, clamped to 0...1 and rounded to 3 decimals. With no windows, `left` is nil.

A cooldown overrides everything: if `Cooldowns.until(harness:) > now`, then `left = 0`, `coolingUntil` is set, and `source = "usage limit cooldown"`.

**`static func writeClaudeStatusline(stdinJSON: Data, paths: HubPaths, now: Date) -> String`.** This backs `agenthubctl statusline`.
- It saves `{five_hour, seven_day, as_of}` from the input's `rate_limits`; the input's `used_percentage` fields are numbers.
- It returns the status text `"<model display_name> · 5h N% · 7d N%"`, skipping missing parts.
- On bad input it returns `""` and writes nothing.

`public enum Cooldowns` stores data in `paths.cooldowns` as `[key: Date]`. Keys are `harness:<id>`, `model:<id>` and `account:<executable>`.
- `set(key, until, paths)`.
- `until(key, paths, now) -> Date?`; this prunes expired keys.
- `static func fromOutput(_ text: String, now: Date) -> TimeInterval?`:
  - It returns nil unless the text matches the limit regex `(?i)\b429\b|RESOURCE_EXHAUSTED|usage limit|rate limit|quota (?:reached|exceeded|exhausted)|Individual quota`.
  - Otherwise it returns the seconds parsed from `(?i)resets? in\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?`, defaulting to 1800, with a minimum of 60.

## 3. Policy — `Sources/HubCore/Policy.swift` (pure, no I/O)

```swift
public struct Snapshot { config; usage: [String: UsageReading]; sessions: [MainSession] /*live, not handed off*/; jobs: [Job] /*queued+running*/; now: Date }
public enum Band: Int, Comparable { case exhausted, wrapUp, single, reduced, healthy }
public enum PolicyAction: Equatable {
  case wrapUp(session: MainSession, target: ModelEntry?, reason: String)   // ask session to finish step + hand off to target
  case autoHandoff(session: MainSession, target: ModelEntry)              // watchdog: hub writes handoff + launches target
  case notify(String)
}
public enum PolicyEngine { ... }
```

**`left(s, harness) -> Double?`** returns 0 when the harness is cooling, otherwise the reading's `left`. nil means unknown.

**`band(s, harness)`.** With `L = left` and limits `lim`:

| condition | band |
|---|---|
| L is nil | healthy |
| `L ≤ exhaustedAtOrBelow` | exhausted |
| `L < wrapUpBelow` | wrapUp |
| `L < singleSessionBelow` | single |
| `L < sameHarnessMinLeft` | reduced |
| otherwise | healthy |

**`sessionCap(s, harness) -> Int`** is `maxMainSessions` for healthy or reduced, 1 for single, and 0 for wrapUp or exhausted.

**`canStartMain(s, modelId) -> (ok: Bool, reason: String)`.** The model must exist, be enabled and be a main model. The session total must be below `maxMainSessions`. Sessions on that harness must be below `sessionCap`.

**`minIntelligence(size, kind)`** is `max(lim.minIntelligence[size.rawValue], kind == .implement ? 0 : lim.minIntelligence[kind.rawValue])`.

**`workerCap(s, harness) -> Int`:**
- healthy: `maxJobs`;
- reduced: 1, if `left ≥ workerMinLeft`;
- otherwise 0.

**`pickWorker(s, size, kind, privacy, mainModel: String?) -> ModelEntry?`:**
- Return nil when running jobs are already `>= maxJobs`.
- Candidates must be enabled, have `isWorker` set and have `intelligence ≥ minIntelligence`.
- `privacy == .project` requires `harness.trusted`.
- Running jobs on the candidate's harness must be below `workerCap`.
- **Same-harness rule:** if the candidate's harness equals the main model's harness, the harness must have `left ≥ sameHarnessMinLeft`, or unknown usage. This rule is the reason the main keeps its own quota.
- Sort key, ascending:
  1. same harness as the main (false first);
  2. intelligence (smallest capable first);
  3. `-(left ?? 0.5)`;
  4. running jobs on the harness;
  5. id.

**`bestMain(s, excludingHarness: String?, planned: [String: Int]) -> ModelEntry?`:**
- Candidates: enabled main models whose harness is not excluded, and where current sessions plus `planned[harness]` on that harness are below `sessionCap`.
- Sort:
  1. harness with no sessions and nothing planned first ("if nothing is running in Claude, move to Claude");
  2. higher intelligence;
  3. `mainOrder` index;
  4. higher left (unknown counts as 0.5).

**`rebalance(s, alreadyWarned: Set<String /*MainSession.id*/>) -> [PolicyAction]`** is deterministic.
- `planned` starts empty. For each harness, sessions run from the most recent `lastSeen` to the oldest.
  - **Keep** the first `sessionCap` sessions.
  - **Move each excess session:** if it is not already warned, emit `.wrapUp(session, target: bestMain(excluding: harness, planned), reason)` and add 1 to `planned[target.harness]`.
  - **Wrap-up band:** a harness in that band has a cap of 0, so the last session also gets `.wrapUp`.
  - **Global cap:** when the total number of sessions exceeds `maxMainSessions`, also wrap up the excess. Take sessions from the lowest-band harness first, then the oldest `lastSeen`.
- **Watchdog:** for each session in `alreadyWarned` whose harness band is exhausted, whose `warned` is at least `graceSeconds` before `now`, and that has a target from `bestMain`, emit `.autoHandoff`.
- **Notify:** emit `.notify` once per call for each harness that is exhausted with no target available.

**`explain(s) -> [String]`** returns human-readable lines for the dashboard, for example "Codex 34% left → reduced: no same-harness delegation; 1 worker job max".

## 4. Relay — `Sources/HubCore/Relay.swift`

`public struct Relay` holds `paths`, `config` and `ctlPath: String` (the absolute path to agenthubctl, used inside instructions). It also has:
- `push: ([String]) -> Bool`, which defaults to `Proc.run` returning passed;
- `openScript: (URL) -> Bool`, which defaults to `Proc.run(["open","-a",config.terminalApp, path])`.

**Sessions** are stored at `paths.sessions/<FileStore.key(harness, sid)>.json` as `MainSession`.

`touch(harness, sid, cwd, event, model, pid, now)`:
- It creates the session or updates `lastSeen`, `lastEvent` and `cwd`, and records `model` and `pid` when non-nil.
- Status is `ended` for SessionEnd, `idle` for Stop, and `working` otherwise.

`sessions(activeOnly: Bool = true, now)` lists sessions. When `activeOnly` is set it drops sessions that are ended, handed off, or not seen for `activeSeconds`.

**Inbox** is stored at `paths.inbox/<key>.json` as `[InboxMessage]`.
- `send(harness, sid, text, kind, now) throws -> InboxMessage`:
  - It runs `Secrets.assertClean`, then appends to the inbox.
  - If the harness has `queueArgs`, it also pushes via `push(Proc.fill(queueArgs, [exe, session, text]))` and records `pushed`.
- `pending(harness, sid)` returns messages that are not done.
- `markDone(harness, sid, kind?)`.

**`hook(harness, event, payload: [String: Any], env: [String: String], now) -> [String: Any]?`** never throws.
- It does nothing when `env[HubPaths.workerEnv] != nil`.
- `sid` is `payload["session_id"] ?? payload["thread_id"]`; with no sid it does nothing.
- It calls `touch`, using `payload["cwd"]`, `payload["model"]` and `payload["agent_pid"]` as an Int. agenthubctl fills `agent_pid` in; see §8.
- For SessionStart and SessionEnd it returns nil.
- Otherwise it applies wrap-ups for this session from the current policy: it calls `checkSession(harness, sid, snapshot, now)`, which sends a wrap_up when `PolicyEngine.rebalance` returns `.wrapUp` for this session and none is pending. It then sets `session.warned = now`.
- **UserPromptSubmit and PostToolUse:**
  - Undelivered messages are rendered once as additional context, and their `delivered` time is set.
  - The messages stay pending.
  - It returns `["hookSpecificOutput": ["hookEventName": event, "additionalContext": text]]`.
- **Stop:**
  - Messages with `stopBlocks < maxStopBlocks` are rendered and `stopBlocks` is incremented.
  - Non-wrap_up messages are marked done.
  - It returns `["decision": "block", "reason": text]`. This keeps an idle session working.
- **Render format:** a header line `Instruction from Agent Hub (the user's orchestrator); act on it once the current request is done:`, followed by one `[agent-hub <kind>] <text>` line per message.

**Wrap-up text** reads:

> `<Harness name> usage is low, so this session moves to <target name>. Finish the current step only, write a handoff file (goal, done, in progress, next steps, files touched, gate command), then run: '<ctlPath>' handoff --from <harness> --session <sid> --project '<cwd>' --file <handoff file> and stop.`

If no target is available it reads "…usage is low and no other main model has capacity; finish the current step, write the handoff file and stop."

**`handoff(from harness, session: String?, project: String, file: String, to modelId: String?, launch: Bool, automatic: Bool, now) throws -> HandoffRecord`:**
- **Validate:** the project must be an existing directory. The file must be relative (resolved under the project) or absolute, must exist, and must pass `Secrets.assertClean` on its content.
- **Pick the target:** `to`, or `PolicyEngine.bestMain(excluding: harness)`. Throw `HubError.noCapacity` when there is none.
- **Write the prompt:** `paths.handoffs/<id>.prompt.txt` reads "Continue the work described in the handoff file <abs file>. Read it first, then continue from 'next steps'. You are now the main model; delegate bounded work with '<ctlPath>' delegate …".
- **Write the launch script:** `paths.handoffs/<id>.command` (mode 755) runs `#!/bin/zsh`, `cd <quoted project>`, then `exec <quoted filled mainArgs>`. Placeholders: exe is the resolved harness executable, plus model, effort (model.effort ?? "high"), project, and `prompt = "$(cat <quoted prompt file>)"`. The prompt is passed literally inside double quotes, and the other arguments are single-quoted with `Proc.quote`.
- **Launch:** if `launch` is set, call `openScript`.
- **Record:** save to `paths.handoffs/<id>.json`, mark the session's wrap_up done and set the session's `handedOff = true`.
- **Interrupt:** if `automatic` is set and `interruptOnAutoHandoff` is on and the session has a pid, call `kill(pid, SIGINT)` through an injectable closure.

**`autoHandoffText(session, now) -> String`** builds a markdown handoff from:
- `git -C cwd status --short` and `git log --oneline -5`, run with `Proc.run` and a 10-second timeout;
- the last 5 jobs for that project from `JobStore` if it is available, otherwise skip them;
- the note "Automatic handoff: the previous main model ran out of usage before writing its own handoff."

It writes this to `paths.handoffs/auto-<key>.md`.

**`apply(_ actions: [PolicyAction], now) -> [String]`** executes actions and returns log lines.
- `wrapUp`: send, unless one is pending, then set `warned`.
- `autoHandoff`: write `autoHandoffText`, then `handoff(automatic: true, launch: config.autoLaunch)`.
- `notify`: return the line.

## 5. HookInstaller — `Sources/HubCore/HookInstaller.swift`

`public struct HookInstaller { claudeSettings: URL = ~/.claude/settings.json; codexHooks: URL = ~/.codex/hooks.json; ctlPath: String }`

- **`install() throws -> [String]`** adds one hook group per event to each file: SessionStart, UserPromptSubmit, PostToolUse (Claude matcher `"*"`), Stop and SessionEnd.
  - The command is `'<ctlPath>' hook <harnessId> <Event>`, with timeout 10.
  - Before the first change it backs each file up as `<file>.bak-agenthub`.
  - It is idempotent: groups whose command contains `agenthubctl` are replaced, never duplicated.
  - All other keys and hook groups are preserved byte-for-byte as JSON values; use JSONSerialization.
  - It creates the file when it is missing.
- **`installStatusLine(force: Bool) throws -> String`** sets `statusLine = {"type":"command","command":"'<ctlPath>' statusline"}` in the Claude settings. It does so only when there is none or the existing one contains `agenthubctl`, or when `force` is set; otherwise it returns a message explaining what is there.
- **`uninstall() throws`** removes only the agenthubctl groups (and the status line if it is ours).
- **`status() -> [String: Bool]`** reports whether each file has our hooks.
- **`installCLILink(at: URL = ~/.local/bin/agenthubctl) throws`** creates or replaces a symlink to ctlPath.

## 6. Jobs — `Sources/HubCore/JobStore.swift` + `Sources/HubCore/Runner.swift`

**`JobStore(paths)`** stores one file per job at `paths.jobs/<id>.json`. It provides:
- `save`, `get(id)`, `all()` (newest first) and `active()` (queued and running);
- `enqueue(_ job) throws`. Before enqueueing it validates:
  - `project` is an existing directory;
  - 1–24 unique relative `allowedFiles`, with no `..`, no absolute paths and no hidden or sensitive names;
  - `checkArgv` has 1–32 non-empty strings;
  - the objective is 1–8000 characters;
  - `Secrets.assertClean` passes on the objective, the files and the argv.

**`Runner(paths, config)`** has injectable `exec: ([String], cwd, env, stdin, timeout) -> CheckResult`, which defaults to `Proc.run`.
- **`func start(_ job: Job, worker: ModelEntry, now) -> Job`** runs synchronously; the Engine calls it on a background queue.
  - **Lock:** one running job per checkout. Use `flock` on `paths.locks/<sha-of-checkout>.lock`, non-blocking. If it is held and `isolation == .worktree`, create `git worktree add <project>/.agenthub-worktrees/<id> -b agenthub/<id>` and run there, recording `worktree` and `branch`. If it is held and `isolation == .checkout`, return the job still queued.
  - **Prompt:** contains role (kind), objective, allowed files, the privacy class, the acceptance argv and the rules: "only edit allowed files, do not spawn workers, do not read credentials, run the acceptance argv before finishing." For `generic` privacy, the prompt omits the absolute paths.
  - **Command:** `Proc.fill(harness.workerArgs, …)`. Run it with env plus `AGENT_HUB_WORKER=1`, the job timeout, and stdin when `promptViaStdin` is set.
  - **Account failover:** on a quota error (`Cooldowns.fromOutput` is not nil), set the cooldown key `account:<exe>` when the harness has accounts, otherwise `model:<id>`. Retry with the next account. When all are exhausted, set `harness:<id>`, append a `JobAttempt`, and return the job `queued` with `harness` and `model` cleared, so the Engine re-picks a worker. Cap this at 3 attempts per job, after which it is `failed`.
  - **Gate:**
    - **Snapshot:** take a snapshot before and after (`git status --porcelain=v1 -uall` plus SHA-256 of each listed file).
    - **Changed files:** the files that differ.
    - **Scope:** `outsideAllowed` is the changed files that match no `allowedFiles` glob (fnmatch).
    - **Acceptance:** run `checkArgv` with no shell and a 600-second timeout.
    - **Result:** state `verified` if `gate.passed`, otherwise `needsReview`.
  - **Output:** a compact form.
    - Codex `--json`: the last `item.completed` `agent_message` text.
    - Claude `--output-format json`: `.result`.
    - Otherwise: the last 4000 characters.
- **`cancel(id)`** terminates a running job's process (keep the PID in memory) and marks it `cancelled`.
- **`mergeWorktree(job) throws`** runs `git -C project merge --no-ff agenthub/<id>`, then removes the worktree. It is only allowed for `verified` jobs.

## 7. Engine — `Sources/HubCore/Engine.swift`

`@MainActor public final class Engine: ObservableObject` publishes `config`, `usage`, `sessions`, `jobs`, `handoffs`, `log: [String]` and `explain: [String]`.

**`tick(now)`** runs every 30 seconds from a timer, and also on demand:
1. Read usage.
2. Read sessions and jobs.
3. Run `rebalance`, then `relay.apply`.
4. Schedule work: while a queued job exists and `pickWorker` returns a model, call `runner.start` on a background queue. Respect `maxJobs`. A job whose `harness` and `model` are preset keeps them if the policy allows.
5. Append notifications to `log`.

It also exposes:
- `delegate(...)`, which enqueues and then ticks;
- `startMain(modelId, project)`, which checks `canStartMain`, writes the handoff-style launch script with the prompt "You are the main model for <project>…" and opens it;
- `send`, `handoff`, `cancel`, `merge`, `saveConfig`.

## 8. CLI — `Sources/agenthubctl/main.swift`

Subcommands, using plain `CommandLine.arguments` parsing with no external libs:
- **`hook <harness> <event>`:**
  - Reads JSON from stdin and adds `agent_pid`: the parent process, skipping up past `sh`/`zsh`/`bash`/`env` parents via `sysctl` `KERN_PROC_PID`.
  - Runs `Relay.hook`. It never fails: on any error it exits 0 with no output, and it prints the result JSON if any.
- **`statusline`:** runs `UsageMeter.writeClaudeStatusline`.
- **`status [--json]`:** prints usage, bands, sessions, jobs and the `explain` lines.
- **`delegate --main <modelId> --size … --kind … --privacy … --project … --objective … --allowed-file F… --check '<json argv>' [--worktree] [--wait] [--dry-run]`:**
  - `--dry-run` prints the `pickWorker` choice.
  - Otherwise it enqueues the job. If the app is not running (no heartbeat in `paths.root/engine.json` within 90 seconds) or `--wait` is given, it runs the job inline via Runner and prints the result JSON.
- **`send --harness … --session … --message …`**
- **`handoff --from … --project … --file … [--session …] [--to modelId] [--no-launch]`**
- **`sessions [--all]`**
- **`tick`:** runs one Engine-equivalent tick without SwiftUI.
- **`install-hooks [--statusline] [--force]`** and **`uninstall-hooks`.**

## 9. App — `Sources/AgentHub/*.swift`

The app uses SwiftUI on macOS 14, with a `MenuBarExtra` and a main `Window`.

**Menu bar.** It shows a per-harness usage bar with its band colour, live sessions, running and queued job counts, the latest log lines, and buttons: Open Hub, Tick now and Quit.

**Main window.** It has a sidebar with these sections:
- **Dashboard:**
  - usage cards per harness, showing windows, reset times, the band and the `explain` lines;
  - session and job counts against their caps;
  - recent handoffs.
- **Sessions:**
  - a table showing harness, model, project, status, last seen and warned;
  - actions: Send message, Hand off to (picker), Stop (wrap-up now);
  - "New main session" (pick a model and project folder), which is disabled with a reason when `canStartMain` fails.
- **Jobs:**
  - a queue and history table showing state, worker, gate, changed files and output;
  - actions: Cancel, Merge worktree and Re-run;
  - a "New job" form.
- **Models:**
  - an editable table: id, harness, name, intelligence slider, main/worker/free/enabled toggles and effort;
  - reorder `mainOrder` by drag;
  - "Add main model".
- **Harnesses:** editable executable, accounts, trusted, usage source, manual left and the argument templates, with a "Test" button that resolves the executable.
- **Settings:**
  - limits steppers and sliders, with a live preview of the band thresholds;
  - auto-launch and terminal app;
  - "Install hooks", "Install status line", "Install command-line tool" and "Uninstall hooks", with status shown;
  - "Open data folder".

**Notifications.** Post them via `UNUserNotificationCenter` for wrap-ups, handoffs and finished jobs, only when `Bundle.main.bundleIdentifier != nil`. The ctl path is `Bundle.main.bundleURL/Contents/MacOS/agenthubctl`, with a fallback to the sibling of the executable.

## 10. Build and distribution — `scripts/build-app.sh`, `README.md`, `Resources/Info.plist`

`scripts/build-app.sh [--dmg] [--identity "<name>"]`:
1. Build with `swift.sh build -c release --disable-sandbox`.
2. Assemble `build/Agent Hub.app`:
   - `Contents/MacOS/AgentHub`;
   - `Contents/MacOS/agenthubctl`;
   - `Contents/Info.plist`: bundle id `dev.agenthub.AgentHub`, `LSUIElement` false, minimum system 14.0, and a version taken from `git describe` or 0.1.0.
3. Run `codesign --force --deep -s "${IDENTITY:--}"` (ad hoc by default).
4. Optionally build a `build/AgentHub.dmg` with hdiutil, containing a symlink to /Applications.

The README covers:
- what the app does;
- the requirements (macOS 14 and Xcode or a working CLT; the AI CLIs you use);
- build steps;
- first open (right-click › Open, or `xattr -dr com.apple.quarantine "Agent Hub.app"`);
- installing hooks;
- how the policy works (the bands table);
- adding a main model;
- privacy rules.
