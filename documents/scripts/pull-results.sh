#!/usr/bin/env bash
# Rsyncs scenario outputs from the GPU VM to documents/outputs/ on your local machine.
# Runs on the Mac.
#
# Usage: bash pull-results.sh <scenario-name>
# Example: bash pull-results.sh merge_highway_01
set -euo pipefail

SSH_ALIAS="alpamayo-vm"
POD_OUTPUTS="/workspace/alphamayo/documents/outputs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_OUTPUTS="$(cd "$SCRIPT_DIR/.." && pwd)/outputs"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <scenario-name>"
    echo "Example: $0 merge_highway_01"
    exit 1
fi

SCENARIO_NAME="$1"
LOCAL_DEST="$LOCAL_OUTPUTS/$SCENARIO_NAME"

echo "==> Pulling results for: $SCENARIO_NAME"
echo "    Source: $SSH_ALIAS:$POD_OUTPUTS/$SCENARIO_NAME/"
echo "    Destination: $LOCAL_DEST/"

# Check connectivity
echo ""
echo "Checking connectivity to $SSH_ALIAS..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_ALIAS" echo "ok" 2>/dev/null; then
    echo "ERROR: Cannot reach $SSH_ALIAS. Verify the pod is running."
    exit 1
fi
echo "  ok   Connected."

# Check source directory exists on the pod
echo ""
echo "Checking source directory on the pod via ssh..."
if ! ssh "$SSH_ALIAS" "test -d $POD_OUTPUTS/$SCENARIO_NAME"; then
    echo "ERROR: $POD_OUTPUTS/$SCENARIO_NAME does not exist on the pod."
    echo "       Run run-scenario.sh first to generate outputs."
    exit 1
fi
echo "  ok   Source directory exists."

# Create local destination
mkdir -p "$LOCAL_DEST"

# Rsync
echo ""
echo "Rsyncing..."
rsync -avz --progress \
    "${SSH_ALIAS}:${POD_OUTPUTS}/${SCENARIO_NAME}/" \
    "${LOCAL_DEST}/"

echo ""
echo "==> Done. Files are at: $LOCAL_DEST/"
ls -lh "$LOCAL_DEST/"

echo ""
echo "Outputs include:"
echo "  - rollouts/.../rollout.asl                            (binary chain-of-causation log)"
echo "  - rollouts/.../*_camera_front_wide_120fov_default.mp4 (DEFAULT layout video)"
echo "  - rollouts/.../*_camera_front_wide_120fov_reasoning_overlay.mp4"
echo "  - aggregate/metrics_results.txt                       (eval metrics)"
