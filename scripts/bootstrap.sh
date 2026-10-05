#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
flutter create . --project-name voidrauvpn --org pm.dnschanger --platforms=android,windows
if command -v python3 >/dev/null 2>&1; then
  PYTHON="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON="python"
else
  echo "Error: Python not found" >&2
  exit 1
fi
"$PYTHON" scripts/apply_overlays.py
echo "Scaffold ready. Fetch cores with: bash scripts/fetch_cores.sh"
