#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
swift build
exec .build/debug/Goldfish 2>&1 | tee "$ROOT/goldfish-debug.log" "$HOME/Library/Logs/Goldfish/console.log"
