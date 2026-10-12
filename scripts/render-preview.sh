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
/usr/bin/xcrun --no-cache swiftc -swift-version 5 -D LIL_TOKEN_QA \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" -framework AppKit -framework ApplicationServices -framework Carbon \
  Sources/UsageModels.swift Sources/ClaudeBridge.swift Sources/OptionShortcut.swift \
  Sources/Theme.swift Sources/UsagePanel.swift Tests/RenderPanel.swift -o .build/render-panel
.build/render-panel
