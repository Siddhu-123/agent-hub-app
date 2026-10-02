# Live feed spec (HubCore + agenthubctl)

Goal: `agenthubctl hook <platform> <event>` becomes the ONLY hook for all four harnesses (claude, codex, antigravity, opencode). It keeps the existing Relay behaviour and additionally maintains a live feed of every session, which the Agent Hub app and the Notch app read. It replaces the Python bridge in `docs/reference/notch-agent-bridge.py` (port its behaviour faithfully; `docs/reference/test_bridge.py` shows expected behaviour).

## Feed location and format
Root: `HubPaths.live` (`<hub root>/live`), folders `sessions/`, `requests/`, `responses/`, `platforms/` (mode 0700), plus `hub.json` (app heartbeat) and `notch.json` (Notch heartbeat). Files are written atomically (temp + rename, mode 0600).
The JSON keys and value types of session, request, response and platform files must be EXACTLY those the Python bridge writes (camelCase keys, times as epoch seconds Double, `pid` integer, file names `<platform>-<safe_id>.json`, request ids `<platform>-<12 hex>`), because Notch parses them unchanged. Use JSONSerialization dictionaries for the files.

`notch.json` (written by Notch): `{"alive_at": Double, "hold_permissions": Bool, "hold_seconds": Int}`.
`hub.json` (written by the app through `LiveFeed.writeHeartbeat`): `{"alive_at": Double, "jobs": [{"id","harness","model","objective"(clipped 160),"project"(basename only),"started"(Double)}], "usage": {"<harness>": {"left": Double|null, "band": String}}, "hooks": {"claude": Bool, "codex": Bool, "antigravity": Bool, "opencode": Bool}}`.
Alive = `alive_at` within the last 6 seconds.

## New file Sources/HubCore/LiveFeed.swift (public API)
```swift
public struct LiveFeed: Sendable {
    public init(paths: HubPaths, pollInterval: TimeInterval = 0.15)
    /// Handles one hook event. Returns the JSON object to print, or nil.
    /// pid = agent pid (CLI passes agentPID()), hostApp = bundle id of the hosting app (see hostApp(env:platform:)).
    public func handle(platform: String, event: String, payload: [String: Any], env: [String: String], pid: Int32?, now: Date = Date()) -> [String: Any]?
    public static func hostApp(env: [String: String], platform: String) -> String
    public func sessions(now: Date = Date()) -> [LiveSession]   // Codable structs mirroring the session file; prunes like Notch does
    public func requests(now: Date = Date()) -> [LiveRequest]
    public func respond(requestId: String, decision: String)    // writes responses/<id>.json {"decision": ...}; allow|always|deny|app only
    public func hubAlive(now: Date = Date()) -> Bool
    public func notchState(now: Date = Date()) -> (alive: Bool, hold: Bool, holdSeconds: Double)
    public func writeHeartbeat(jobs: [Job], usage: [String: UsageReading], bands: [String: String], hooks: [String: Bool], now: Date = Date())
    public func markStopped()                                    // alive_at = 0
    public func shouldLaunchHub(now: Date = Date()) -> Bool      // true when hub not alive AND no launch attempt recorded in the last 15 s; records the attempt (file live/launch-attempt) under FileStore.withLock(paths, "live-launch")
}
```
Adapt the parameter types of writeHeartbeat to the real `Job`/`UsageReading` types in HubCore; never put full paths in hub.json (project = last path component).

Behaviour, ported from the bridge:
- claude & codex (same contract): SessionStart, UserPromptSubmit, PreToolUse (incl. AskUserQuestion question bubble), PostToolUse, Notification (permission_prompt, elicitation_dialog, idle_prompt), Stop, SessionEnd, PermissionRequest (blocking hold, returns `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{...}}}`, "always" passes `permission_suggestions` as `updatedPermissions`).
- antigravity: PreInvocation, PostToolUse, Stop (CLI must ALWAYS print `{}` for antigravity, even on errors or empty stdin).
- opencode: busy, tool, title, idle, error, permission (non-blocking, returns `{"requestId": id}`, stores `externalId`), permission-replied, question.
- describe_tool, request_summary, question_from_args, verb_for, clip, short_path, readable_args: same output strings.
- Holding a PermissionRequest happens only when Notch is alive with hold_permissions AND `hubAlive`. Hold seconds clamp 5...540. Wait loop polls `responses/<id>.json` every pollInterval; stops early when Notch dies or the request file disappears; on timeout or "app" the request becomes passive (release_to_app).
- `env[HubPaths.workerEnv] != nil` → return nil and write nothing (hub workers are not shown).
- platforms/<platform>.json is written on every event.
- Activity log (Activity.log, low volume, no prompt/command/path text): `live.session` with detail `event: start|end`, `project` (basename) when a session file is first created / removed; `live.permission` with `tool` and `outcome` (`allow|always|deny|released|passive`).
- Never throw out of handle: any error → nil (antigravity → `{}`).

## agenthubctl hook (Sources/agenthubctl/main.swift)
- Accept platforms claude, codex, antigravity, opencode. Empty or invalid stdin: antigravity prints `{}`, others print nothing; exit 0 always.
- claude/codex: call the existing `relay.hook` ONLY for SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd (unchanged behaviour), and `LiveFeed.handle` for every event. Print the LiveFeed output if non-nil (PermissionRequest), otherwise the Relay output.
- Auto-launch: when `AGENT_HUB_TEST` and `AGENT_HUB_WORKER` are both unset and `feed.shouldLaunchHub()` is true, run `/usr/bin/open -g -b dev.agenthub.AgentHub` (`HubPaths.appBundleID`) with Proc.run timeout 5, before handling the event. Must never fail the hook.

## HookInstaller (Sources/HubCore/HookInstaller.swift)
Add injectable `geminiDirs: [URL]` (default `~/.gemini/antigravity`, `~/.gemini/antigravity-cli`, `~/.gemini/antigravity-ide`) and `opencodeConfigDir: URL` (default `~/.config/opencode`), plus `livePath` for the plugin.
- Claude events: SessionStart, UserPromptSubmit, PreToolUse (matcher "*"), PostToolUse ("*"), Notification, Stop, SessionEnd, PermissionRequest ("*", timeout 600); others timeout 10.
- Codex events: SessionStart, UserPromptSubmit, PreToolUse ("*"), PostToolUse ("*"), Stop, SessionEnd, PermissionRequest ("*", timeout 600).
- In both files remove retired groups: any group whose command contains `notch-agent-bridge` or `agent-hub/startup/hub-hook.py`. All other groups/keys are preserved (e.g. a group that runs `open -ga Antigravity` must stay).
- Antigravity: for each gemini dir that exists, read `hooks.json` (or {}), back it up once, remove key `notch-agents`, set key `agent-hub` = `{"enabled": true, "PreInvocation": [cmd], "PostToolUse": [{"matcher": "*", "hooks": [cmd]}], "Stop": [cmd]}` where cmd = `{"type":"command","command":"'<ctl>' hook antigravity <Event>","timeout":5}`.
- OpenCode: if the config dir exists, write `plugin/agent-hub.js` from a template (new file Sources/HubCore/OpenCodePlugin.swift, a Swift string) that is a port of `docs/reference/opencode-notch-plugin.js` spawning `<ctl> hook opencode <event>` directly (no python) and watching `<live>/responses` and `<live>/requests`; ctl and live paths are embedded with JSON string escaping. If `plugin/notch-agents.js` exists, rename it to `plugin/notch-agents.js.bak-agenthub` (never delete).
- uninstall removes our Claude/Codex groups, the `agent-hub` key, and `plugin/agent-hub.js`. status() also reports antigravity and opencode.

## Tests (Swift Testing, temp AGENT_HUB_HOME / temp dirs only, never real home)
New Tests/HubCoreTests/LiveFeedTests.swift covering at least: session lifecycle files and keys (claude), Notification idle/permission bubbles, AskUserQuestion question bubble, PermissionRequest not held when hub or notch not alive (returns nil, passive request), held + answered allow/always/deny (answer written from another thread), worker env writes nothing, antigravity and opencode flows (permission returns requestId, permission-replied clears it), describe_tool strings, shouldLaunchHub rate limit, heartbeat contains basename only, pruning of dead pid sessions. Extend HookInstallerTests for new events, retired-group removal with other groups preserved, antigravity key swap, opencode plugin write + rename.

## Gate
`sh scripts/test.sh` must pass fully. Do not edit Paths.swift, Proc.swift, Relay.swift or Package.swift. Remove nothing else.
