#!/bin/sh
set -euo pipefail

BUILD_DMG=false
IDENTITY="${IDENTITY:--}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg)
      BUILD_DMG=true
      shift
      ;;
    --identity)
      if [ -z "${2:-}" ]; then
        echo "Error: --identity requires a value" >&2
        exit 1
      fi
      IDENTITY="$2"
      shift 2
      ;;
    --identity=*)
      IDENTITY="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--dmg] [--identity <name>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 1. Build release binaries via swift.sh
"$REPO_ROOT/scripts/swift.sh" build -c release --disable-sandbox

BIN_DIR="$("$REPO_ROOT/scripts/swift.sh" build -c release --show-bin-path)"
if [ ! -f "$BIN_DIR/AgentHub" ] || [ ! -f "$BIN_DIR/agenthubctl" ]; then
  if [ -f "$REPO_ROOT/.build/release/AgentHub" ]; then
    BIN_DIR="$REPO_ROOT/.build/release"
  elif [ -f "$REPO_ROOT/.build/out/Products/Release/AgentHub" ]; then
    BIN_DIR="$REPO_ROOT/.build/out/Products/Release"
  fi
fi

if [ ! -f "$BIN_DIR/AgentHub" ]; then
  echo "Error: AgentHub executable not found in $BIN_DIR" >&2
  exit 1
fi

if [ ! -f "$BIN_DIR/agenthubctl" ]; then
  echo "Error: agenthubctl executable not found in $BIN_DIR" >&2
  exit 1
fi

# 2. Assemble build/Agent Hub.app
BUILD_DIR="$REPO_ROOT/build"
APP_DIR="$BUILD_DIR/Agent Hub.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cp "$BIN_DIR/AgentHub" "$MACOS_DIR/AgentHub"
cp "$BIN_DIR/agenthubctl" "$MACOS_DIR/agenthubctl"
chmod +x "$MACOS_DIR/AgentHub" "$MACOS_DIR/agenthubctl"

# Determine version from git describe --tags or default to 0.1.0
# CFBundleVersion must be numeric, so only a plain x.y[.z] tag (optionally v-prefixed) is used.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$'; then
  VERSION="0.1.0"
fi

INFO_PLIST_TEMPLATE="$REPO_ROOT/Resources/Info.plist"
if [ ! -f "$INFO_PLIST_TEMPLATE" ]; then
  echo "Error: Resources/Info.plist not found" >&2
  exit 1
fi

cp "$INFO_PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
sed -i '' "s/__VERSION__/$VERSION/g" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
plutil -replace CFBundleIdentifier -string "dev.agenthub.AgentHub" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleExecutable -string "AgentHub" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace LSMinimumSystemVersion -string "14.0" "$CONTENTS_DIR/Info.plist"
plutil -replace NSHighResolutionCapable -bool true "$CONTENTS_DIR/Info.plist"
plutil -replace LSUIElement -bool false "$CONTENTS_DIR/Info.plist"

# 3. Codesign
codesign --force --deep -s "$IDENTITY" "$APP_DIR"

# 4. Optional DMG creation
if [ "$BUILD_DMG" = true ]; then
  DMG_PATH="$BUILD_DIR/AgentHub.dmg"
  DMG_STAGING="$(mktemp -d -t agenthub_dmg)"
  cp -R "$APP_DIR" "$DMG_STAGING/"
  ln -s /Applications "$DMG_STAGING/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -volname "Agent Hub" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
  rm -rf "$DMG_STAGING"
  echo "Created $DMG_PATH"
fi

# 5. Verification: both executables exist and are executable, plutil -lint passes, codesign --verify passes
echo "Verifying application bundle..."

if [ ! -f "$MACOS_DIR/AgentHub" ] || [ ! -x "$MACOS_DIR/AgentHub" ]; then
  echo "Verification failed: $MACOS_DIR/AgentHub missing or not executable" >&2
  exit 1
fi

if [ ! -f "$MACOS_DIR/agenthubctl" ] || [ ! -x "$MACOS_DIR/agenthubctl" ]; then
  echo "Verification failed: $MACOS_DIR/agenthubctl missing or not executable" >&2
  exit 1
fi

if ! plutil -lint "$CONTENTS_DIR/Info.plist"; then
  echo "Verification failed: plutil -lint on $CONTENTS_DIR/Info.plist failed" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$APP_DIR"; then
  echo "Verification failed: codesign --verify on $APP_DIR failed" >&2
  exit 1
fi

echo "Successfully built and verified: $APP_DIR"
