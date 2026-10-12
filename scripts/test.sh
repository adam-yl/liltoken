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
compile() {
    /usr/bin/xcrun --no-cache swiftc -swift-version 5 \
      -module-cache-path "$SWIFT_MODULECACHE_PATH" "$@"
}
compile -framework AppKit -framework ApplicationServices -framework Carbon Sources/OptionShortcut.swift Tests/OptionShortcutTests.swift -o .build/option-tests
.build/option-tests
compile Sources/UsageModels.swift Sources/ClaudeBridge.swift Tests/ClaudeBridgeTests.swift -o .build/claude-tests
.build/claude-tests
compile -framework Security Sources/UsageModels.swift Sources/ClaudeProvider.swift Tests/ClaudeProviderTests.swift -o .build/claude-provider-tests
.build/claude-provider-tests
compile Sources/UsageModels.swift Sources/CodexProvider.swift Tests/CodexProviderTests.swift -o .build/codex-tests
.build/codex-tests
compile Sources/UsageModels.swift Tests/LocalStoreTests.swift -o .build/store-tests
.build/store-tests
