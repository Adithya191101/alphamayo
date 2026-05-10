#!/usr/bin/env bash
# Runs a single AlpaSim scenario with Alpamayo 1.5 as the driver on the GPU VM.
# Runs locally; execution happens on the VM via ssh.
#
# Usage: bash run-scenario.sh <scenario-name> [scene-id]
#
# Prerequisites: vm-bootstrap.sh has completed successfully on the VM.
set -euo pipefail

SSH_ALIAS="${SSH_ALIAS:-alpamayo-vm}"
WORKSPACE="/workspace"
PROJECT_DIR="$WORKSPACE/alphamayo"
ALPASIM_DIR="$WORKSPACE/alpasim"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <scenario-name> [scene-id]"
    echo "  scenario-name: a label for this run (used as output folder name)"
    echo "  scene-id:      optional. AlpaSim picks a default scene if omitted."
    echo ""
    echo ""
    echo "Examples:"
    echo "  $0 my_first_run"
    echo "  $0 construction_zone clipgt-<scene-uuid-here>"
    exit 1
fi

SCENARIO_NAME="$1"
SCENE_ID="${2:-}"
OUTPUT_DIR="$PROJECT_DIR/documents/outputs/$SCENARIO_NAME"

echo "==> Running scenario: $SCENARIO_NAME"
[[ -n "$SCENE_ID" ]] && echo "    Scene ID: $SCENE_ID"
echo "    All simulation commands run on the VM via ssh ($SSH_ALIAS)."

# Check connectivity
echo ""
echo "Checking connectivity to $SSH_ALIAS..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_ALIAS" echo "ok" 2>/dev/null; then
    echo "ERROR: Cannot reach $SSH_ALIAS. Verify the VM is running."
    exit 1
fi
echo "  ok   Connected."

# Create output directory on the VM
echo ""
echo "Creating output directory on the VM via ssh..."
ssh "$SSH_ALIAS" "mkdir -p $OUTPUT_DIR"

# Build the wizard command
WIZARD_ARGS="deploy=local topology=1gpu driver=alpamayo1_5 wizard.log_dir=$OUTPUT_DIR"
if [[ -n "$SCENE_ID" ]]; then
    WIZARD_ARGS="$WIZARD_ARGS scenes=[$SCENE_ID]"
fi

# Run AlpaSim — source ~/.bashrc so HF_TOKEN is in env, set UV_LINK_MODE=copy for NFS-safe installs
echo ""
echo "==> Running AlpaSim wizard on the VM via ssh..."
echo "    Command: uv run alpasim_wizard $WIZARD_ARGS"
echo ""
ssh "$SSH_ALIAS" "source ~/.bashrc; source ~/.local/bin/env 2>/dev/null; \
  cd $ALPASIM_DIR && \
  UV_LINK_MODE=copy uv run alpasim_wizard $WIZARD_ARGS \
  2>&1 | tee $OUTPUT_DIR/run.log"

echo ""
echo "==> Scenario complete."
echo "    Output on VM:  $OUTPUT_DIR/"
echo "    Pull results:  bash documents/scripts/pull-results.sh $SCENARIO_NAME"
