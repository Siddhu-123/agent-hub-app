# Activity log + live monitoring (implement exactly this)

Goal: a durable, append-only event log so the user can watch orchestration live and later analyse it for improvements.

## HubCore/Activity.swift (new)
- `public struct ActivityEvent: Codable, Equatable { ts: Date; kind: String; job: String?; harness: String?; model: String?; detail: [String: String] }`
- `public enum Activity`:
  - `static func record(_ e: ActivityEvent, paths: HubPaths)` appends one JSON line to `paths.logs/events.jsonl` (create dir; ISO8601 dates; never throws; guarded by `FileStore.withLock(paths, "activity")` or an equivalent flock so concurrent processes don't interleave). Rotate: when the file exceeds 10 MB, rename it to `events-<yyyyMMdd-HHmmss>.jsonl` first; keep only the newest 5 rotated files.
  - Convenience `static func log(_ kind: String, job: String? = nil, harness: String? = nil, model: String? = nil, _ detail: [String: String] = [:], paths: HubPaths, now: Date = Date())`.
  - `static func read(paths: HubPaths, since: Date? = nil, limit: Int = 500) -> [ActivityEvent]` (newest file only, tolerant of bad lines, returns oldest→newest, last `limit`).
  - `static func stats(_ events: [ActivityEvent]) -> ActivityStats` with: per model {started, verified, failed, queuedBack, avgSeconds}; masked {attempted, passed, fallbacks, fallbackReasons: [reason prefix (first 60 chars): count]}; handoffs count; wrapUps count; cooldowns count.
- Detail values are short strings: truncate any value to 300 chars. Never put objectives, prompts, file contents or worker output in events (privacy); project = last path component only.

## Emit events (kinds are exact)
- Engine: `job.queued` (size, kind, privacy, project), `job.started` (harness, model, broker if any, route=masked|sandbox|direct), `job.finished` (state, seconds, changed=<count>, gate=pass|fail|none).
- Runner masked path: `masked.mask` (ok|fail), `masked.scan` (ok | problems=<count>), `masked.heavy` (attempt=<n>, check=pass|fail), `masked.decode` (ok|fail), `masked.fallback` (reason truncated to 120 chars, no worker output).
- Runner: `cooldown` whenever Cooldowns.set is called (key, until).
- Relay: `session.event` for hook events SessionStart/SessionEnd only (harness, session prefix 8, project), `policy.wrapup`, `policy.handoff` (from, to, automatic), `policy.handoff_failed`, `usage` when a usage reading changes by ≥5 points (harness, percentLeft).
Use the Runner/Engine/Relay `paths`; tests must use temp HubPaths (never the real home).

## agenthubctl
- `monitor [--follow] [--json]`: print the last 50 events as `HH:mm:ss kind job model detail k=v ...`; with `--follow` poll the file every 1 s and print new lines until killed (handle rotation). `--json` prints raw lines.
- `stats [--json]`: print ActivityStats as a compact table (and JSON with --json).
- Add both to `CLIArgs.usage`; add `follow` to switches.

## GUI (Sources/AgentHub)
- New `ActivityView.swift`: a live list (newest first, refresh every 2 s via Activity.read) with a kind filter (All/Jobs/Masked/Policy/Sessions) and a stats header (verified %, masked pass %, fallbacks, handoffs). Add it as an "Activity" tab/sidebar item in MainWindow next to Jobs, matching existing view style in Components.swift.

## README
- Short "Live monitoring" section: events.jsonl location, `agenthubctl monitor --follow`, `agenthubctl stats`, Activity tab.

## Tests (Tests/HubCoreTests/ActivityTests.swift, Swift Testing)
- record/read round trip; bad lines skipped; rotation at a tiny threshold (make the threshold an internal static var for tests); stats counts from a synthetic event list; a Runner masked fake-exec run (copy the pattern in MaskedTests) emits masked.mask, masked.heavy, masked.decode and job events without any objective text in the file.

Gate: `sh scripts/test.sh` must pass in full. Do not change existing behaviour or other tests. Do not commit.
