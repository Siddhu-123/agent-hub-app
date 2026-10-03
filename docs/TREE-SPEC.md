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

## E. Chat transcript on main nodes

Goal: a main-model card (and its drawer) shows the exact words of the conversation — the user's messages and the model's replies, verbatim — with tool calls as short dim lines.

### E1. HubCore: `Sources/HubCore/Transcript.swift`

```swift
public struct ChatEntry: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant, tool }
    public var role: Role
    public var text: String
    public init(role: Role, text: String)
}
public enum Transcript {
    /// The session's transcript file. `hint` (the hook's transcript_path) wins when that file exists.
    /// Otherwise claude: the first `<claudeRoot>/<any folder>/<sessionId>.jsonl` that exists;
    /// codex: the newest file under `<codexRoot>` (recursive) whose name ends with "-<sessionId>.jsonl".
    /// Other platforms or nothing found: nil. sessionId must match [A-Za-z0-9._-]{1,128}, else nil.
    public static func locate(platform: String, sessionId: String, hint: String?,
                              claudeRoot: URL = <home>/.claude/projects, codexRoot: URL = <home>/.codex/sessions) -> URL?
    /// Reads the last maxBytes of the file (dropping the first partial line unless reading from offset 0) and parses it.
    public static func entries(_ url: URL, maxBytes: Int = 400_000) -> [ChatEntry]
    /// Parses JSONL text (one JSON object per line; invalid lines are skipped). Both formats may appear; order is kept.
    public static func parse(_ jsonl: String) -> [ChatEntry]
}
```

Claude lines (`type` user/assistant, content in `message.content`, a string or an array of blocks):
- Skip lines with `isMeta == true` or `isSidechain == true`.
- `user`: a string content, or each `text` block, becomes a user entry after removing every `<system-reminder>…</system-reminder>` span and trimming. Drop it when empty or when it starts with `<local-command-`, `<command-name>`, `<command-message>`, `<task-notification>` or `Caveat:`. `tool_result` blocks are ignored.
- `assistant`: each `text` block becomes an assistant entry (trimmed, exact text, not clipped). Each `tool_use` block becomes a tool entry `"<name> <arg>"` where arg is the first non-empty string among input `command`, `file_path`, `pattern`, `url`, `query`, `description`, `prompt`, cut to its first line and 160 characters (`<name>` alone when none). `thinking` blocks are ignored.

Codex lines:
- `type == "event_msg"` with `payload.type == "item_completed"`, by `payload.item.type`:
  - `UserMessage`: user entry, the `text` of its `content` items joined with "\n", trimmed.
  - `AgentMessage`: assistant entry, same joining.
  - `CommandExecution`: tool entry `"$ <cmd>"`; `command` is an array — when it is `[shell, "-lc", script]` (shell ending in `sh`) use the script, else join with spaces; first line, 160 characters.
  - `McpToolCall`: tool entry `"<server>.<tool>"` plus `" — <arguments.title>"` when that is a non-empty string.
  - `FileChange`: tool entry `"✎ "` + the last path component of each key in `changes`, sorted, joined with ", ".
  - `Extension` with `query` string: tool entry `"search <query>"` (160 characters).
  - Others ignored.
- `type == "event_msg"` with `payload.type == "user_message"` / `"agent_message"` (older Codex): user / assistant entry from `payload.message`.
- `response_item` lines are ignored (they repeat the above and contain injected instructions).
- Consecutive identical entries (same role and text) collapse into one. Empty texts are dropped.

### E2. LiveFeed / LiveSession
- `LiveSession` gains `transcript: String?` (in the memberwise init as the last parameter, default nil).
- In the Claude/Codex branch, the shared `context` dictionary also carries `"transcript": d["transcript_path"] ?? ""` so every event that writes context stores the path (empty strings are not written, as today).

### E3. Tests: `Tests/HubCoreTests/TranscriptTests.swift`
Cover: Claude user string, user with system-reminder only (dropped), command caveat (dropped), assistant text + tool_use, meta and sidechain skipped; Codex UserMessage, AgentMessage, CommandExecution with `-lc`, FileChange, McpToolCall, old user_message/agent_message; invalid lines; duplicate collapse; `entries` with maxBytes smaller than the file (first partial line dropped); `locate` for claude and codex with temp roots, hint precedence, invalid session id; LiveFeed stores `transcript` from a UserPromptSubmit payload.

### E4. App
- `TreeModel` locates each main node's transcript (cache the URL per session; retry locate when nil at most every 10 s) and re-parses only when the file's size or modification date changed. It publishes `chats: [String: [ChatEntry]]` keyed by node id (last 40 entries), and the drawer's full chat for a selected main node (last 400 entries).
- A main card's terminal shows the chat: user entries in an accent colour prefixed `you › `, assistant entries in white with their full text wrapped (not one line), tool entries dim, prefixed `· `. It is bottom-anchored and clipped at the top, so the newest words are always visible. Falls back to the current activity lines when there is no transcript. Main cards are 460 × 340.
- The drawer for a main node shows the full chat: each entry with a role label (`YOU`, the model id, or `tool`), text selectable, following new messages.

## F. Token-driven wire blobs

Blobs on a wire move only while the child node is actually receiving output, and how many there are, how fast they move, and how big and bright they look follow the real amount written.

### F1. Measuring flow (TreeModel, on the background refresh queue)
- Each refresh (1 s) samples the byte size of every active node's source file:
  - worker / broker / check nodes: the job log `JobLog` file for `jobId` (`logs/jobs/<id>.log`); only the job's currently active node gets the job's growth;
  - main nodes: the session transcript (the URL already located for E4);
  - subagent nodes: the parent main session's transcript growth.
- Growth since the previous sample, in bytes, is converted to tokens as `bytes / 4` (rounded up). A shrinking or first-seen file counts as 0.
- `TreeModel` publishes `flows: [String: [Pulse]]` keyed by node id, where `Pulse { launched: Date; duration: Double; weight: Double }`. For a delta of `n > 0` tokens it appends `k = min(6, max(1, ceil(n / 60)))` pulses with launch times spread evenly across the next refresh interval. It also keeps a per-node running average of `n` (exponential, α = 0.3, over non-zero samples only). Each pulse's `weight` is `n / average` clamped to `0.5...1.5`. Its `duration` is `1.6 s / clamp(rate / average, 0.75, 1.5)`, so heavier bursts travel faster. Pulses older than `launched + duration` are dropped. When nothing was written, no new pulses are added.

### F2. Drawing (Connectors)
- Remove the constant, time-driven packet loop and the constantly marching dash. A wire with no pulses in flight shows only its static lit state (glow and core for active nodes, as now).
- Each pulse is drawn as the existing packet blob at `u = smoothstep((now - launched) / duration)` (ease in and out, not linear).
- Size and brightness vary within a 20 % range driven by the pulse's tokens: `scale = 1 + flowRange * (weight - 1)` with `flowRange = 0.2` and `weight` mapped from `0.5...1.5` (so scale and opacity stay within `0.9...1.1` of their base). Keep `flowRange` a single named constant.
- The marching dash moves only while at least one pulse is in flight on that wire, at a speed proportional to the number of pulses in flight.
- The `TimelineView` is paused when no wire has pulses in flight and no dispatch comet is running.
- The dispatch comet (first activation) stays as it is.
