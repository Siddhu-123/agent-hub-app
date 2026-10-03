# Tree view spec

Goal: one full-screen view that shows every live session as a tree of windows — the main model at the root, its subagents (researchers) and hub worker jobs as children, masked brokers and gate checks below the jobs — with each node showing what is happening in its terminal, and current flowing along a connector while work is in flight on it.

## A. Live job log (HubCore)

`Sources/HubCore/JobLog.swift`:

```swift
public enum JobLog {
    /// <paths.logs>/jobs/<id>.log
    public static func url(_ paths: HubPaths, _ id: String) -> URL
    /// Appends raw bytes. Creates the folder (0700) and file (0600). Ignores ids that are not [A-Za-z0-9._-]{1,80}.
    public static func append(_ paths: HubPaths, _ id: String, _ data: Data)
    /// Appends "── <text> ──\n" on its own line (adds a leading newline when the file does not end with one).
    public static func mark(_ paths: HubPaths, _ id: String, _ text: String)
    /// Last maxBytes of the log as text: starts at a line boundary, ANSI escape sequences and \r removed. "" when missing.
    public static func tail(_ paths: HubPaths, _ id: String, maxBytes: Int = 16_384) -> String
    /// Keeps the newest `keep` logs by modification date and removes the rest.
    public static func prune(_ paths: HubPaths, keep: Int = 200)
}
```

- `Proc.run` gains `onOutput: ((Data) -> Void)? = nil`, called with every chunk read from the child (including the final drain).
- `Runner.Exec` gains a 7th parameter `@escaping (Data) -> Void`. The default exec passes it to `Proc.run(onOutput:)`. Every exec the Runner does for a job (worker, check, masked steps) streams into `JobLog.append(paths, job.id, …)`.
- Stage markers via `JobLog.mark`: `worker <model> (<harness>)`, `check <argv joined by space>`, `gate passed|failed · changed N · outside M`, `MASK <broker>`, `HEAVY <model> attempt N`, `masked check pass|fail`, `DECODE <broker>`, and finally `job <state>`.
- `Runner.start` calls `JobLog.prune(paths)` once.

## B. Parent link and subagents (HubCore)

- `Job.parentSession: String?` — `"<harness>:<sessionId>"` of the main session that delegated the job.
- `CLIArgs.jobFromDelegateArgs(_:now:env:)` with `env: [String: String] = ProcessInfo.processInfo.environment`: sets `parentSession = "claude:<CLAUDE_CODE_SESSION_ID>"` when that variable is non-empty, else `"codex:<CODEX_THREAD_ID>"` when that one is, else nil.
- `LiveSession` gains `recent: [LiveLine]?` and `agents: [LiveAgent]?`:

```swift
public struct LiveLine: Codable, Equatable, Sendable { public var t: Double; public var text: String }
public struct LiveAgent: Codable, Equatable, Sendable {
    public var id, type, description, status, activity: String   // status: running | done
    public var startedAt: Double
    public var finishedAt: Double?
    public var recent: [LiveLine]?
}
```

- LiveFeed, Claude/Codex branch:
  - Every time a session's `activity` is set, append `{t, text: activity}` to `recent` (skip if equal to the last text; keep the last 12).
  - `PreToolUse` with `tool_name` in `Task`, `Agent`: append an agent `{id: tool_use_id, type: tool_input.subagent_type ?? "general-purpose", description: clip(tool_input.description ?? tool_input.prompt, 80), status: running, activity: "Starting", startedAt: now}`.
  - `PostToolUse` with `tool_name` in `Task`, `Agent`: the agent with `id == tool_use_id` becomes `done` with `finishedAt`.
  - A payload with a non-empty `agent_id` comes from a subagent: its `PreToolUse` updates the newest running agent (prefer one whose `type == agent_type`) — its `activity` and `recent` — and leaves the parent's `activity`/`recent` alone (the parent still gets `steps + 1`).
  - Drop `done` agents finished more than 10 minutes ago; keep at most 12 agents.

## C. Tree model (HubCore)

`Sources/HubCore/HubTree.swift`:

```swift
public struct HubNode: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case main, subagent, worker, broker, check }
    public var id: String
    public var role: Role
    public var title: String        // model id / agent type
    public var subtitle: String     // session title, objective or description
    public var status: String       // live status or job state
    public var activity: String     // one-line "what now"
    public var active: Bool         // work in flight on the edge into this node (root: session working)
    public var startedAt: Date?
    public var jobId: String?
    public var lines: [String]      // recent activity for main/subagent nodes
    public var children: [HubNode]
}
public enum HubTree {
    public static func build(sessions: [LiveSession], jobs: [Job], modelHarness: [String: String], now: Date) -> [HubNode]
}
```

- One root per session (`id "s:<platform>:<sessionId>"`) that is working/waiting, has a linked job that is queued/running, or was updated in the last 30 minutes. Sorted: working/waiting first, then `updatedAt` newest first.
- Subagent children (`id "a:<agentId>"`), then job children (`id "j:<jobId>"`), newest first.
- A job belongs to the session named by `parentSession`; otherwise to the session whose `cwd` equals the job project (standardized path) and whose platform equals `modelHarness[job.mainModel]`, picking the newest `updatedAt`. Unlinked jobs go under a synthetic root `id "orphans"`, title "Unattached jobs".
- Jobs shown: queued/running, or finished within the last 30 minutes; at most 8 per root.
- Job node: role worker, title `model ?? "waiting for a worker"`, subtitle objective (clipped 160), status = state, active = running. Children: a broker node (`"b:<jobId>"`, title broker, subtitle "mask · decode") when `broker` is set, and a check node (`"c:<jobId>"`, title check argv joined (clipped 60), status `pending` / `passed` / `failed` from `gate`).

## D. App: Tree view

New sidebar item "Tree" (first, the default). The view fills the window (sidebar collapses while it is shown), with a session strip on top (All + one chip per root, status dot) and an infinite, pannable, zoomable canvas below. Nodes are window cards (title bar with traffic-light dots, role badge, model, status, elapsed; body: a dark terminal pane with the tail of the job log or the session's recent lines). Connectors are curves from parent bottom to child top; while a child is `active`, glowing pulses travel along the connector toward it. A newly started job flashes its connector. Clicking a node opens a bottom drawer with its full live log, following new output.
