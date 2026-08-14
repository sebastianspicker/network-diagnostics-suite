#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

if ! command -v pwsh >/dev/null 2>&1; then
  echo "pwsh not found. Install PowerShell 7+ first." >&2
  exit 1
fi

exec pwsh -NoProfile -NonInteractive -File "$REPO_ROOT/Invoke-NetworkLantern.ps1" "$@"
