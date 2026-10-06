# Agent Hub guide for main models (Codex, Claude)

Agent Hub (`/Applications/Agent Hub.app`) is the user's orchestration console. The CLI is `agenthubctl` (`~/.local/bin/agenthubctl`, a link into the app). The app runs the policy, the queue, the sandbox and the hooks; a main model only plans, delegates, reviews and accepts.

## Roles
- **Main model**: the model in the conversation (Codex `gpt-6.1-sol`, Claude `claude-opus-5-5`). It keeps the context, splits work into bounded jobs, delegates them and accepts results.
- **Worker**: a model started by the hub for one job. It has `AGENT_HUB_WORKER=1` in its environment. A worker executes its envelope directly: no delegation, no hub commands, no app launches.

## Start of a project conversation
```
agenthubctl status
```
Shows usage left per harness, its band (healthy / reduced / single / wrap-up / exhausted), active sessions and jobs. Respect the band: in `single` only one main session may run; in `exhausted` hand off.

Each session has a state: `idle` (between turns), `running` (working), `waiting` (on a permission prompt or notification), `exhausted` (its harness is out of quota, or its handoff is blocked; `handoff_blocked` says why) or `ended`. An exhausted or wrapped-up session no longer holds a main slot. If a handoff launched the session for one model and it reports another, the model column shows `(expected X, got Y)` and the session gets a message.

## Delegate every bounded subtask
```
agenthubctl delegate --main gpt-6.1-sol --project "$PWD" \
  --objective "<self-contained task>" \
  --allowed-file <path> [--allowed-file <path> ...] \
  --check '["<command>","<arg>"]' \
  --size tiny|routine|hard --kind implement|review|plan \
  [--privacy project|generic] [--worker HARNESS/MODEL] \
  [--worktree] [--offload auto|always|never] [--split N | --fanout] --wait
```
- `--dry-run` prints the chosen worker (and broker) without running anything.
- Model references accept raw ids when unique or qualified ids such as `claude/claude-opus-5-5`. OpenCode ids keep their slash in the id, so `opencode/space-bunny-free` qualifies as `opencode/opencode/space-bunny-free`; the harness still receives the raw id. `--worker` pins a specific worker.
- `--check` is the acceptance argv (JSON array, no shell). It must pass for the job to be `verified`.
- `--allowed-file` limits what the worker may change; edits elsewhere fail the gate.
- `--worktree` runs the job in the checkout when it is free and in a git worktree when another job holds the checkout, so parallel jobs never collide.
- `--privacy project` (default) keeps project data with trusted models. Hard project jobs are offloaded through the masked pipeline: a trusted broker masks names and paths, a free sandboxed model does the work on the masked copy, the broker decodes it back and the gate runs. `--offload never` keeps a job on trusted models; `--offload always` forces masking.
- The free worker is fenced by sandbox-exec to its own stage: it can read, edit and run shell commands (tests) there, but not `/Users`, `/Volumes`, other temp dirs, other jobs' stages or the mask map. The masked check runs in the same fence. If a free worker fails, the job is requeued for another free provider (the failed one is excluded, see `maskedTried`) and then for a trusted worker; it never stays stuck.
- `--offload always` masks a job of any size. If no broker sits in the usual 55–79 intelligence range, the least capable trusted worker brokers instead.
- `--split N` / `--fanout` cuts a project implement job by file into N masked slices (`--fanout`: one per available provider), each sent to a free worker from a different provider. It needs at least N allowed files, N free providers and a broker; otherwise it refuses with the reason. The output lists the slices' receipts plus `providers` / `distinctProviders`. Run slices in parallel with the app running and `--worktree`.
- A fan-out `--check` usually covers the whole job, so a slice alone ends `needs_review`. With `--wait`, once every slice has finished cleanly (no edits outside its files) the hub merges the worktree slices into the checkout and runs the check once. If it passes, every slice becomes `verified`. If it fails, the checkout is restored. The output's `combined` holds `{passed, applied, output}`. The gate ignores interpreter caches (`__pycache__`, `*.pyc`, `.pytest_cache`, `.DS_Store`).
- `--privacy generic` is only for tasks with no project data at all.
- The objective must stand alone: workers do not share the conversation.

Output is a JSON receipt. Every receipt carries `state` (`verified`, `failed`, `needs_review`, `queued`), `model`, `zdr`, `masked`, `maskedClasses` (kinds of data the broker hid: name, path, url, email, domain, key, identifier), `gate`, `gatePassed`, `note` and `permissionDenials`, plus `harness`, `broker`, `output`. A queued receipt says why in `note` and gives `resetsAt` when known. An implement job that changed no files ends `failed` with note `no changes / writes denied` and lists the denials. Exit code 0 = verified, 1 = failed or needs review, 3 = still queued (no capacity). Quota failure never retries in a loop: the router falls back to another free/ZDR worker or returns queued.

Accept a result only after reading the diff and confirming the gate. A worker's success message is not proof.

## Size guide
- `tiny`: one small edit, obvious check.
- `routine`: a normal feature or fix in a few files.
- `hard`: cross-cutting work, tricky logic, heavy implementation.

## Messages from the hub
Hub messages arrive at prompt time, prefixed `[agent-hub <kind>]`.
- `[agent-hub wrap_up]`: finish the current step only, write a handoff file (goal, done, in progress, next steps, files touched, gate command), run the exact `agenthubctl handoff ...` command in the message, then stop. Another main model continues from the file.
- `[agent-hub message] <Harness> available — its quota reset ...`: that harness can take worker jobs again (sent once per reset).
- Other kinds: act on them after the current request.

wrap_up is sent once, when usage left drops to the wrap-up reserve (default 10–15% left, i.e. 85–90% used; set in Settings → Limits). With it the hub writes `handoffs/auto-<harness>_<session>.md` (last objective, files changed since the session started, last build/test result); a session that dies without handing off keeps that file for the next main model. A failed handoff is recorded as `handoff_blocked` with the fix and retried at most once per grace period.

## Handoff by hand
```
agenthubctl handoff --from codex --project "$PWD" --file <handoff.md> [--to claude-opus-5-5] [--no-launch]
```

## ZDR workers (user-approved only)
A free worker may run project jobs directly (no masking) only when the provider retains no data. The setup belongs to the user; agents must not change it.
1. In the model entry, the user sets `zdr: true`, `zdrSource` (where the policy is stated, e.g. the provider's policy URL) and `zdrDate` (when it was checked). Entries without both are ignored.
2. In Settings → General the user enables "Let ZDR-listed workers run project jobs" (`zdrProjectWorkers`).
3. `agenthubctl models --zdr` lists the allowlist with source and date. ZDR jobs still run in the sandbox stage, and their receipt shows `zdr: true, masked: false`.

## Live monitoring
- `agenthubctl monitor --follow` streams orchestration events (jobs, masked steps, cooldowns, handoffs, usage changes, `session.state` transitions, `policy.reset`, `session.model_mismatch`).
- `agenthubctl stats` summarises success rates per model, masked pass rate, fallback reasons and handoffs.
- Events live in `~/Library/Application Support/AgentHub/logs/events.jsonl` (or `$AGENT_HUB_HOME/logs`). The app's Activity tab shows the same.

## Rules
- Never send credentials, tokens or secret files to any model; never put them in objectives.
- Never call free third-party models directly on project files; the hub's masked pipeline is the only route.
- Do not edit the hub's config or hooks unless the user asks.
- Preserve existing edits; do not delete user work.
