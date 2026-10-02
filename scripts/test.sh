#!/bin/sh
# Builds everything, then runs the HubCore tests. Usage: scripts/test.sh [TestFilter]
set -e
here="$(dirname "$0")"
sh "$here/swift.sh" build --disable-sandbox
if [ -n "$1" ]; then exec sh "$here/swift.sh" test --disable-sandbox --filter "$1"; else exec sh "$here/swift.sh" test --disable-sandbox; fi
