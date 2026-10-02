#!/bin/sh
# Builds everything, then runs the HubCore tests. Usage: scripts/test.sh [TestFilter]
set -e
here="$(dirname "$0")"
# Keeps Relay from opening real terminals or signalling real processes during tests.
export AGENT_HUB_TEST=1
sh "$here/swift.sh" build --disable-sandbox
if [ -n "$1" ]; then exec sh "$here/swift.sh" test --disable-sandbox --filter "$1"; else exec sh "$here/swift.sh" test --disable-sandbox; fi
