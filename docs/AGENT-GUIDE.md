# Agent Hub guide for main models (Codex, Claude)

Agent Hub (`/Applications/Agent Hub.app`) is the user's orchestration console. The CLI is `agenthubctl` (`~/.local/bin/agenthubctl`, a link into the app). The app runs the policy, the queue, the sandbox and the hooks; a main model only plans, delegates, reviews and accepts.

## Roles
- **Main model**: the model in the conversation (Codex `gpt-6.1-sol`, Claude `claude-opus-5-5`). It keeps the context, splits work into bounded jobs, delegates them and accepts results.
- **Worker**: a model started by the hub for one job. It has `AGENT_HUB_WORKER=1` in its environment. A worker executes its envelope directly: no delegation, no hub commands, no app launches.

## Start of a project conversation
```
agenthubctl status
```
Shows usage left per harness, its band (healthy / reduced / single / exhausted), active sessions and jobs. Respect the band: in `single` only one main session may run; in `exhausted` hand off.

## Delegate every bounded subtask
```
agenthubctl delegate --main gpt-6.1-sol --project "$PWD" \
  --objective "<self-contained task>" \
  --allowed-file <path> [--allowed-file <path> ...] \
  --check '["<command>","<arg>"]' \
  --size tiny|routine|hard --kind implement|review|plan \
  [--privacy project|generic] [--worktree] [--offload auto|always|never] --wait
```
- `--dry-run` prints the chosen worker (and broker) without running anything.
- `--check` is the acceptance argv (JSON array, no shell). It must pass for the job to be `verified`.
- `--allowed-file` limits what the worker may change; edits elsewhere fail the gate.
- `--worktree` runs the job in the checkout when it is free and in a git worktree when another job holds the checkout, so parallel jobs never collide.
- `--privacy project` (default) keeps project data with trusted models. Hard project jobs are offloaded through the masked pipeline: a trusted broker masks names and paths, a free sandboxed model does the work on the masked copy, the broker decodes it back and the gate runs. `--offload never` keeps a job on trusted models; `--offload always` forces masking.
- `--privacy generic` is only for tasks with no project data at all.
- The objective must stand alone: workers do not share the conversation.

Output is a JSON receipt. Key fields: `state` (`verified`, `failed`, `queued`), `model`, `harness`, `broker`, `gate.changedFiles`, `gate.acceptance.exitCode`, `note`, `output`. Exit code 0 = verified, 1 = failed, 3 = still queued (no capacity).

Accept a result only after reading the diff and confirming the gate. A worker's success message is not proof.

## Size guide
- `tiny`: one small edit, obvious check.
- `routine`: a normal feature or fix in a few files.
- `hard`: cross-cutting work, tricky logic, heavy implementation.

## Messages from the hub
Hub messages arrive at prompt time, prefixed `[agent-hub <kind>]`.
- `[agent-hub wrap_up]`: finish the current step only, write a handoff file (goal, done, in progress, next steps, files touched, gate command), run the exact `agenthubctl handoff ...` command in the message, then stop. Another main model continues from the file.
- Other kinds: act on them after the current request.

## Handoff by hand
```
agenthubctl handoff --from codex --project "$PWD" --file <handoff.md> [--to claude-opus-5-5] [--no-launch]
```

## Live monitoring
- `agenthubctl monitor --follow` streams orchestration events (jobs, masked steps, cooldowns, handoffs, usage changes).
- `agenthubctl stats` summarises success rates per model, masked pass rate, fallback reasons and handoffs.
- Events live in `~/Library/Application Support/AgentHub/logs/events.jsonl` (or `$AGENT_HUB_HOME/logs`). The app's Activity tab shows the same.

## Rules
- Never send credentials, tokens or secret files to any model; never put them in objectives.
- Never call free third-party models directly on project files; the hub's masked pipeline is the only route.
- Do not edit the hub's config or hooks unless the user asks.
- Preserve existing edits; do not delete user work.
