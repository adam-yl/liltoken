#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_ROOT"
export LIL_TOKEN_PROJECT_ROOT="$PROJECT_ROOT"
/usr/bin/python3 -B scripts/check-paths.py
export TMPDIR="$PROJECT_ROOT/.build/tmp/"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export XDG_CACHE_HOME="$PROJECT_ROOT/.build/cache"
export XCRUN_CACHE_DIR="$PROJECT_ROOT/.build/cache"
APP="$PROJECT_ROOT/.build/Lil Token.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/xcrun --no-cache swiftc -swift-version 5 -O -g \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -framework AppKit -framework ApplicationServices -framework Carbon -framework ServiceManagement -framework Security \
  Sources/*.swift -o "$APP/Contents/MacOS/LilToken"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LilTokenProjectRoot string $PROJECT_ROOT" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
printf 'Built %s\n' "$APP"
