#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/swift.sh build --disable-sandbox
bin_dir=$(sh scripts/swift.sh build --show-bin-path)
ctl="$bin_dir/agenthubctl"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0 HUP INT TERM
export AGENT_HUB_HOME="$tmp/hub"
# Ensure hooks represent a main session even when this test runs inside a worker.
unset AGENT_HUB_WORKER
payload=$(python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1]}))' "$tmp")
printf '%s\n' "$payload" | "$ctl" hook claude SessionStart
# Keep usage reads hermetic; never inspect installed CLI session logs.
python3 - "$AGENT_HUB_HOME/config.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    config = json.load(f)
for harness in config['harnesses']:
    harness['usageSource'] = 'none'
with open(path, 'w') as f:
    json.dump(config, f)
PY
"$ctl" sessions > "$tmp/sessions.txt"
grep -q s1 "$tmp/sessions.txt"
"$ctl" send --harness claude --session s1 --message hi > "$tmp/sent.json"
printf '%s\n' "$payload" | "$ctl" hook claude UserPromptSubmit > "$tmp/hook.json"
python3 - "$tmp/hook.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    result = json.load(f)
assert 'hi' in result['hookSpecificOutput']['additionalContext']
PY
printf '%s\n' '{"model":{"display_name":"Sample"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":34}}}' | "$ctl" statusline > "$tmp/statusline.txt"
grep -q 5h "$tmp/statusline.txt"
"$ctl" status --json > "$tmp/status.json"
python3 -m json.tool "$tmp/status.json" > /dev/null
mkdir "$tmp/project"
git -C "$tmp/project" init -q
"$ctl" delegate --main gpt-6.1-sol --project "$tmp/project" --objective 'Smoke test' --allowed-file file.swift --check '["true"]' --dry-run
[ ! -d "$AGENT_HUB_HOME/jobs" ]
"$ctl" help > /dev/null
printf '%s\n' 'smoke ok'
