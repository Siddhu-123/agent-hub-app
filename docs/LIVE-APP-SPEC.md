# Live feed in the Agent Hub app

HubCore already has `LiveFeed` (Sources/HubCore/LiveFeed.swift): hooks of all four harnesses write the live feed under `HubPaths.live`. Wire it into the app.

## Engine (Sources/HubCore/Engine.swift)
- Add `public let live: LiveFeed` (built from the engine's paths) and `@Published public private(set) var liveSessions: [LiveSession] = []`, `liveRequests: [LiveRequest] = []`.
- `start()` also schedules a 2-second repeating timer (common run-loop mode) that calls `pulse()`: writes the heartbeat with `live.writeHeartbeat(...)` (active jobs, current usage, each harness's band name exactly as `agenthubctl status` computes it, `hookStatus`), then refreshes `liveSessions` / `liveRequests` (read off the main thread is fine; publish on main, only when changed).
- `stop()` invalidates it and calls `live.markStopped()`.
- `public func respond(_ request: LiveRequest, decision: String)` → `live.respond(...)` and drops the request from `liveRequests` immediately.
- Existing 30-second tick unchanged.

## App target (Sources/AgentHub)
- AgentHubApp: observe `NSApplication.willTerminateNotification` → `engine.stop()` (so held hooks release at once). On launch, if UserDefaults bool `launchNotch` (default true) and no running app has bundle id `HubPaths.notchBundleID`, open it with `NSWorkspace.shared.openApplication` (activates: false). Skip both when `AGENT_HUB_TEST` is set.
- New `LiveView.swift`: list of live sessions grouped by harness (Claude Code, Codex, Antigravity, OpenCode), each row: status dot (working green, waiting orange, idle gray, done blue, error red), title or "Untitled", activity line, project, model, steps, elapsed since `turnStartedAt` or `startedAt`. Above it, pending requests: title, detail, and Allow / Always (only when options contain "always") / Deny buttons when `canAnswer`, otherwise a passive "Answer in the app" label. Empty state: "No agent sessions right now". Reuse styles from Components.swift.
- MainWindow: new sidebar item "Live" (systemImage "dot.radiowaves.left.and.right") as the FIRST item of the "Agent Hub" section, and make it the default selection.
- SettingsView: a "Launch Notch with Agent Hub" toggle bound to `launchNotch`.
- DashboardView: one compact row "Live: N working · M waiting" from `engine.liveSessions`.

No other changes. Gate: `sh scripts/test.sh` passes and `sh scripts/build-app.sh` builds the app.
