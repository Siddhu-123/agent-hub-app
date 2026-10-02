# Agent Hub for macOS

Agent Hub is a native macOS menu bar and window application with an accompanying command-line interface (`agenthubctl`). It orchestrates AI coding assistants—including Claude Code, Codex, Antigravity, and OpenCode—into a unified workflow:

- **Main Sessions**: Interactive, conversational sessions with frontier models (e.g. Claude Opus, Codex GPT-6) for high-level reasoning and architectural direction.
- **Worker Jobs**: Bounded, scoped delegation of routine tasks to smaller, faster, or alternative models, validated with hermetic test verification gates and git worktree isolation.
- **Usage-Aware Policy**: Real-time rate limit tracking across multiple quota windows (5h, 7d) with automatic throttling, multi-session management, and seamless handoffs before quota is exhausted.

Pure Swift, zero third-party dependencies, Foundation-only core, and unsandboxed to drive developer CLI tools directly.

---

## Requirements

- **Operating System**: macOS 14.0 (Sonoma) or newer.
- **Developer Tools**: Xcode 15+ or Command Line Tools (CLT) with Swift 5.10+.
- **AI Coding CLIs**: Any CLI tools you intend to use:
  - Claude Code (`claude`)
  - OpenAI Codex CLI (`codex`)
  - Antigravity CLI (`agy`)
  - OpenCode (`opencode`)

---

## Build & Installation

### Building the Application

Build the release application bundle using the build script:

```bash
sh scripts/build-app.sh
```

This compiles all targets via `scripts/swift.sh build -c release --disable-sandbox` and produces `build/Agent Hub.app`.

### Building a Distributable Disk Image (DMG)

To package `Agent Hub.app` into a UDZO `.dmg` containing an `/Applications` shortcut:

```bash
sh scripts/build-app.sh --dmg
```

Output: `build/AgentHub.dmg`.

### Code Signing

By default, the build script signs the bundle ad-hoc (`-`). To sign with a Developer ID or development identity:

```bash
sh scripts/build-app.sh --identity "Developer ID Application: Your Name (TEAMID)"
```

Or provide the environment variable:

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" sh scripts/build-app.sh
```

### Running Tests

Run the test suite at any time:

```bash
sh scripts/test.sh
```

---

## First Open & Gatekeeper

Because locally built or ad-hoc signed apps are quarantined by macOS Gatekeeper:

1. Right-click `build/Agent Hub.app` in Finder, select **Open**, and confirm **Open**.
2. Or clear the quarantine attribute via Terminal:
   ```bash
   xattr -dr com.apple.quarantine "build/Agent Hub.app"
   ```

Copy or drag `Agent Hub.app` into `/Applications` for regular use.

---

## Installing Hooks

Agent Hub hooks monitor CLI activity, record sessions, track token/rate limits, and inject handoff instructions when quota is low.

### Via the GUI
1. Open the **Settings** view in Agent Hub.
2. Click **Install hooks** to register hook handlers in `~/.claude/settings.json` and `~/.codex/hooks.json`.
3. Click **Install status line** to show live quota usage in Claude's statusline.
4. Click **Install command-line tool** to symlink `agenthubctl` to `~/.local/bin/agenthubctl`.

### Via the Command Line
```bash
"/Applications/Agent Hub.app/Contents/MacOS/agenthubctl" install-hooks --statusline
```

To remove hooks at any time:
```bash
agenthubctl uninstall-hooks
```

---

## Policy & Usage Bands

Agent Hub calculates remaining quota `L` (from `0.0` to `1.0`) across all rate-limit windows (e.g. 5-hour and 7-day sliding windows). Limit cooldowns (such as HTTP 429 or quota exceeded responses) temporarily force `L = 0`.

### Policy Bands Table

| Band | `L` (fraction left) | Main sessions on this harness | Workers on this harness |
|:---|:---|:---:|:---:|
| **`healthy`** | `≥ sameHarnessMinLeft` (0.40), or unknown | `maxMainSessions` (2) | allowed (shared `maxJobs` = 4) |
| **`reduced`** | `0.30 – 0.40` | `maxMainSessions` | 1 (if `L ≥ workerMinLeft` 0.15); never for its own main model |
| **`single`** | `0.15 – 0.30` | 1 (extra sessions move to the next main model on another harness) | none |
| **`wrapUp`** | `0.02 – 0.15` | 0 — the session is asked to finish its step and write a handoff | none |
| **`exhausted`** | `≤ 0.02`, or cooling after a limit error | 0 — automatic handoff to the next main model | none |

Main models are tried in `mainOrder` (intelligence hierarchy, e.g. Claude Opus ↔ GPT Sol). All thresholds, caps and the order are editable in **Settings** and **Models**; changes apply on the next 30-second tick.

---

## Adding a Main Model (e.g. Gemini 4)

When a new frontier model is available, you can add it as a primary conversational model:

### In the UI
1. Navigate to the **Models** section in the Agent Hub sidebar.
2. Click **Add Main Model...**.
3. Enter model details:
   - **ID**: `gemini-4-pro`
   - **Harness**: `antigravity`
   - **Name**: `Gemini 4 Pro`
   - **Intelligence**: `99` (scale 0–100)
   - Enable the **Main** toggle (and optionally **Worker**).
4. Reorder the model within the **mainOrder** list to define its priority relative to other models (e.g. Claude Opus or GPT-6).

### In Code / Configuration
Using `HubCore`:
```swift
ConfigStore.addMainModel(&config, model: ModelEntry(
    id: "gemini-4-pro",
    harness: "antigravity",
    name: "Gemini 4 Pro",
    intelligence: 99,
    isMain: true,
    isWorker: true
))
```
This adds the model, sets `isMain = true`, and appends it to `mainOrder`. The policy engine will immediately consider it when selecting new sessions or finding handoff targets.

---

## Privacy & Isolation Rules

- **Secret Scrubbing**: All prompts, objectives, file paths, and handoff contents pass through `Secrets.assertClean` before being sent to any model or stored.
- **Privacy Classes**:
  - `project`: For proprietary project code. Work is restricted exclusively to trusted harnesses (`harness.trusted = true`). Untrusted harnesses (like local/third-party OpenCode endpoints) are blocked.
  - `generic`: For general algorithmic tasks and non-sensitive logic. Untrusted harnesses may be selected, and absolute file paths are omitted from prompts.
- **Untrusted harnesses** (`trusted = false`, e.g. OpenCode free models) only receive `generic` jobs. Generic objectives may not contain private paths or emails. The worker runs under `sandbox-exec` in a throwaway `/private/tmp` stage that holds copies of the allowed files only; it cannot read `/Users`, `/Volumes` or temp folders, and only the allowed files are copied back. If the macOS sandbox is unavailable, untrusted jobs fail instead of running unsandboxed.
- **Worker Scoping**:
  - Worker jobs are restricted to explicit `allowedFiles` (1–24 relative paths). Changing any other file sends the job to **needs review**.
  - One job edits a project checkout at a time (`flock`). Jobs created with isolation `worktree` run in `~/Library/Application Support/AgentHub/worktrees/<id>` when the checkout is busy; verified worktree jobs are merged from the **Jobs** view.
  - The acceptance command (`checkArgv`) runs without a shell; a job is **verified** only when it passes and every change is inside `allowedFiles`.

---

## Notes

- **Claude usage** comes from the status line hook (Settings → **Install status line**). Without it Claude shows "Usage unknown" and is treated as healthy.
- **Codex hooks** must be approved once inside Codex after installing (Codex trusts hooks by hash).
- If the older Python `agent-hub` hooks are also installed, both sets run; uninstall one to avoid duplicate messages.
- Data lives in `~/Library/Application Support/AgentHub` (`AGENT_HUB_HOME` overrides it).
