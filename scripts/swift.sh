#!/bin/sh
# swift wrapper: uses a full Xcode when xcode-select points at (possibly broken) Command Line Tools.
cd "$(dirname "$0")/.."
if [ -z "$DEVELOPER_DIR" ] && xcode-select -p | grep -q CommandLineTools; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    [ -d "$x" ] && export DEVELOPER_DIR="$x/Contents/Developer" && break
  done
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
exec swift "$@"
