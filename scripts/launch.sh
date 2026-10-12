#!/bin/bash
# Use after approving app registration, normal Codex runtime writes, and shortcut setup.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_ROOT"
export LIL_TOKEN_PROJECT_ROOT="$PROJECT_ROOT"
/usr/bin/python3 -B scripts/check-paths.py
export TMPDIR="$PROJECT_ROOT/.build/tmp/"
export XDG_CACHE_HOME="$PROJECT_ROOT/.build/cache"
/usr/bin/open --env TMPDIR="$TMPDIR" --env XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  "$PROJECT_ROOT/.build/Lil Token.app" --args --show "$@"
