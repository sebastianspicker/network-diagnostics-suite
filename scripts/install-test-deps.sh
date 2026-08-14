#!/usr/bin/env bash
set -euo pipefail

missing=()
for tool in shellcheck bats jq pwsh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if ((${#missing[@]} == 0)); then
  echo "Required local test tools are already available: shellcheck, bats, jq, pwsh."
  echo "Run the local gate with: ./scripts/ci-local.sh"
  exit 0
fi

echo "Missing local test tools: ${missing[*]}" >&2
echo >&2
echo "Install them with your system package manager, for example:" >&2
echo "  macOS/Homebrew: brew install shellcheck bats-core jq powershell/tap/powershell" >&2
echo "  Debian/Ubuntu:  sudo apt-get install shellcheck bats jq && install PowerShell 7+" >&2
echo >&2
echo "After installation, run: ./scripts/ci-local.sh" >&2
exit 1
