#!/usr/bin/env bash
# Verifies local Mac dependencies for the Alpamayo Explore project.
# Safe to re-run. Runs on the Mac.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MISSING=0

check_cmd() {
    if command -v "$1" &>/dev/null; then
        printf "  ok   %s (%s)\n" "$1" "$(command -v "$1")"
    else
        printf "  MISSING  %s\n" "$1"
        MISSING=1
    fi
}

echo "==> Checking local dependencies..."
check_cmd git
check_cmd rsync
check_cmd ssh
check_cmd jq

if [[ $MISSING -eq 1 ]]; then
    echo ""
    echo "Install missing tools with Homebrew: brew install git rsync jq"
    exit 1
fi

echo ""
echo "==> Checking local.env..."
if [[ -f "$PROJECT_ROOT/local.env" ]]; then
    echo "  ok   local.env exists"
else
    echo "  MISSING  local.env not found"
    echo "           Copy local.env.template to local.env and fill in your HF_TOKEN."
fi

echo ""
echo "==> Checking SSH alias alpamayo-vm..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 alpamayo-vm echo "ok" &>/dev/null; then
    echo "  ok   SSH connection to alpamayo-vm succeeded"
else
    echo "  WARNING  Cannot reach alpamayo-vm (VM may be stopped or SSH config not yet set up)"
    echo "           Configure ~/.ssh/config with a 'Host alpamayo-vm' block — see README."
fi

echo ""
echo "==> Checking documents/outputs/ directory..."
mkdir -p "$PROJECT_ROOT/documents/outputs"
echo "  ok   documents/outputs/ exists"

echo ""
echo "Mac setup check complete."
