#!/usr/bin/env bash
# Build from source and install SuperGrok Bar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Building SuperGrokBar (release)…"
swift build -c release --product SuperGrokBar

export SUPERGROK_BAR_EXEC
SUPERGROK_BAR_EXEC="$(swift build -c release --show-bin-path)/SuperGrokBar"
if [[ ! -x "$SUPERGROK_BAR_EXEC" ]]; then
  echo "error: binary not found at $SUPERGROK_BAR_EXEC" >&2
  exit 1
fi

exec "$ROOT/Scripts/supergrok-bar" start
