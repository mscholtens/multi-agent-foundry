#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONFIG="$ROOT/config.local.yaml"

# Sets AZURE_* env vars if SP credentials are configured, so DefaultAzureCredential works.
source "$SCRIPT_DIR/_common.sh"

# ── Python virtual environment ────────────────────────────────────────────────
VENV="$ROOT/.venv"
REQ="$ROOT/requirements.txt"
MARKER="$VENV/.installed"

if [[ ! -d "$VENV" ]]; then
  echo "=== Creating Python virtual environment ==="
  python3 -m venv "$VENV"
fi

# Install (or reinstall) whenever requirements.txt is newer than the last install marker.
# This catches first-run, added packages, and version bumps without hardcoding Python paths.
if [[ ! -f "$MARKER" ]] || [[ "$REQ" -nt "$MARKER" ]]; then
  echo "=== Installing Python dependencies ==="
  "$VENV/bin/pip" install -r "$REQ" --quiet
  touch "$MARKER"
fi

PYTHON="$VENV/bin/python"

echo "=== Multi-Agent Foundry Demo ==="
echo ""

# Determine which tickets to run
if [[ $# -gt 0 ]]; then
  TARGETS="$*"
else
  echo "Which tickets do you want to run?"
  echo "  Enter a file path:    tickets/ticket_A.pdf"
  echo "  Enter a directory:    tickets/"
  echo "  Enter * for all:      *"
  echo ""
  read -r -p "Selection: " INPUT
  if [[ "$INPUT" == "*" || -z "$INPUT" ]]; then
    TARGETS="$ROOT/tickets/"
  else
    TARGETS="$INPUT"
  fi
fi

echo ""
echo "Running: python demo.py $TARGETS"
# shellcheck disable=SC2086
echo ""

cd "$ROOT"
"$PYTHON" demo.py $TARGETS
