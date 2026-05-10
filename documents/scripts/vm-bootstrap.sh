#!/usr/bin/env bash
# Bootstraps a fresh GPU VM for the Alpamayo Explore project.
#
# Tested and working on:
#   - Hyperstack (Ubuntu 22.04 KVM VM, A100 or H100)
#
# Does NOT work on:
#   - RunPod Pods (containers, not VMs — seccomp blocks docker daemon)
#
# Run on your local machine. SSHes to the VM at $SSH_ALIAS.
# Reads HF_TOKEN from local.env (copy local.env.template to local.env first).
#
# Lessons baked in:
#   - Disable apt-daily timers FIRST to avoid 25-min unattended-upgrades wait
#   - Use /ephemeral (or other big disk) as workspace — boot disk too small for AlpaSim
#   - Pre-build alpasim-base:0.70.0 once (serial) before running the wizard,
#     to avoid parallel builds blowing up disk
set -euo pipefail

SSH_ALIAS="${SSH_ALIAS:-alpamayo-vm}"
# Big-disk path for everything heavy (Docker, AlpaSim, weights). Hyperstack
# provides /ephemeral (750+ GB local SSD) on H100/A100 instances.
DATA_ROOT="${DATA_ROOT:-/ephemeral}"
WORKSPACE="/workspace"
PROJECT_DIR="$WORKSPACE/alphamayo"
ALPASIM_DIR="$WORKSPACE/alpasim"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CONFIG="$PROJECT_ROOT/local.env"

echo "==> Bootstrapping GPU VM via SSH ($SSH_ALIAS)"
echo "    All commands run on the VM via ssh — not locally."
echo ""

# Step 1: SSH connectivity
echo "Step 1: Checking SSH connectivity..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_ALIAS" echo "connected" 2>/dev/null; then
    echo "ERROR: Cannot reach $SSH_ALIAS."
    exit 1
fi
echo "  ok   Connected."

# Step 2: Read HF_TOKEN from local config
echo ""
echo "Step 2: Reading HF_TOKEN from local.env..."
if [[ ! -f "$LOCAL_CONFIG" ]]; then
    echo "ERROR: $LOCAL_CONFIG not found."
    exit 1
fi
HF_TOKEN=$(grep -E '^[[:space:]]*export HF_TOKEN=' "$LOCAL_CONFIG" | sed -E 's/.*export HF_TOKEN=//; s/^[[:space:]]+//;s/[[:space:]]+$//' | head -1)
if [[ -z "$HF_TOKEN" || "$HF_TOKEN" == *"hf_your_token_here"* ]]; then
    echo "ERROR: HF_TOKEN not set in local.env."
    exit 1
fi
echo "  ok   HF_TOKEN found."

# Step 3: Disable apt-daily timers BEFORE doing any apt operations
# Otherwise unattended-upgrades grabs the dpkg lock for 25+ min on fresh Ubuntu cloud images.
echo ""
echo "Step 3: Disabling apt-daily timers on the VM (avoid unattended-upgrades lock-out)..."
ssh "$SSH_ALIAS" 'sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service 2>/dev/null; sudo systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>&1 | tail -2; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 5; done; sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && echo LOCK_HELD || echo LOCK_FREE'
echo "  ok   timers masked"

# Step 4: Set up the big-disk workspace
echo ""
echo "Step 4: Setting up workspace on $DATA_ROOT (big-disk location)..."
ssh "$SSH_ALIAS" "
  if [[ ! -d $DATA_ROOT ]]; then
    echo 'ERROR: $DATA_ROOT does not exist on the VM.'
    echo '       Hyperstack should provide /ephemeral on GPU instances.'
    echo '       Check df -h to find a big-disk path; set DATA_ROOT env var.'
    exit 1
  fi
  sudo mkdir -p $DATA_ROOT/workspace $DATA_ROOT/docker
  sudo chown -R \$USER:\$USER $DATA_ROOT/workspace
  if [[ -L $WORKSPACE ]]; then sudo rm $WORKSPACE; fi
  if [[ -d $WORKSPACE && ! -L $WORKSPACE ]]; then sudo rmdir $WORKSPACE 2>/dev/null || sudo mv $WORKSPACE ${WORKSPACE}.old; fi
  sudo ln -sf $DATA_ROOT/workspace $WORKSPACE
  mkdir -p $PROJECT_DIR/documents/outputs $PROJECT_DIR/documents/notebooks
  df -h $DATA_ROOT | tail -1
"
echo "  ok   $WORKSPACE -> $DATA_ROOT/workspace"

# Step 5: GPU check
echo ""
echo "Step 5: Checking GPU on the VM..."
GPU_INFO=$(ssh "$SSH_ALIAS" "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null" || echo "")
if [[ -z "$GPU_INFO" ]]; then
    echo "ERROR: nvidia-smi not available."
    exit 1
fi
echo "  ok   GPU: $GPU_INFO"

# Step 6: Configure Docker to use the big-disk before installing it
echo ""
echo "Step 6: Pre-configuring Docker daemon.json to use $DATA_ROOT/docker..."
ssh "$SSH_ALIAS" "
  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  \"data-root\": \"$DATA_ROOT/docker\",
  \"runtimes\": {
    \"nvidia\": {
      \"args\": [],
      \"path\": \"nvidia-container-runtime\"
    }
  }
}
EOF
  cat /etc/docker/daemon.json
"
echo "  ok   Docker daemon.json configured."

# Step 7: Install Docker (apt) — daily timers are off, lock should be free
echo ""
echo "Step 7: Installing Docker on the VM..."
DOCKER_OK=$(ssh "$SSH_ALIAS" "command -v docker &>/dev/null && echo yes || echo no")
if [[ "$DOCKER_OK" == "no" ]]; then
    ssh "$SSH_ALIAS" "curl -fsSL https://get.docker.com | sudo sh && sudo systemctl enable --now docker && sudo usermod -aG docker \$USER" 2>&1 | tail -5
    echo "  ok   Docker installed."
else
    echo "  ok   Docker present."
fi

# Step 8: Verify Docker daemon and data-root
echo ""
echo "Step 8: Verifying Docker daemon..."
ssh "$SSH_ALIAS" "sudo systemctl restart docker; sleep 3; sudo docker info 2>&1 | grep -E 'Docker Root Dir|Storage Driver' | head -3"

# Step 9: Install NVIDIA Container Toolkit
echo ""
echo "Step 9: Installing NVIDIA Container Toolkit..."
ssh "$SSH_ALIAS" "
  if ! sudo docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | grep -qE 'NVIDIA|H100|A100|RTX'; then
    [[ -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]] || \
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    [[ -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]] || \
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y nvidia-container-toolkit 2>&1 | tail -3
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
  fi
  echo 'Testing GPU passthrough...'
  sudo docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 | tail -1
"

# Step 10: HF token + login
echo ""
echo "Step 10: Logging in to HuggingFace..."
ssh "$SSH_ALIAS" "
  grep -q '^export HF_TOKEN=' ~/.bashrc 2>/dev/null || echo 'export HF_TOKEN=$HF_TOKEN' >> ~/.bashrc
  pip install -q huggingface_hub 2>&1 | tail -1 || sudo pip install -q huggingface_hub 2>&1 | tail -1
  HF_TOKEN=$HF_TOKEN ~/.local/bin/hf auth login --token $HF_TOKEN 2>&1 | tail -2
  HF_TOKEN=$HF_TOKEN ~/.local/bin/hf auth whoami 2>&1 | tail -2
"

# Step 11: Install uv
echo ""
echo "Step 11: Installing uv..."
ssh "$SSH_ALIAS" "command -v uv &>/dev/null || (curl -LsSf https://astral.sh/uv/install.sh | sh)" 2>&1 | tail -2

# Step 12: Install Rust (needed for AlpaSim utils_rs)
echo ""
echo "Step 12: Installing Rust toolchain..."
ssh "$SSH_ALIAS" "command -v cargo &>/dev/null || (curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet)" 2>&1 | tail -2

# Step 13: Clone AlpaSim
echo ""
echo "Step 13: Cloning NVlabs/alpasim..."
ssh "$SSH_ALIAS" "[ -d $ALPASIM_DIR/.git ] && echo 'already cloned' || git clone https://github.com/NVlabs/alpasim.git $ALPASIM_DIR"

# Step 14: setup_local_env.sh
echo ""
echo "Step 14: Running setup_local_env.sh (5-10 min)..."
ssh "$SSH_ALIAS" "source ~/.cargo/env 2>/dev/null; source ~/.local/bin/env 2>/dev/null; cd $ALPASIM_DIR && UV_LINK_MODE=copy bash -c 'source setup_local_env.sh'" 2>&1 | tail -5

# Step 15: uv sync with extras
echo ""
echo "Step 15: uv sync --extra all --extra transfuser..."
ssh "$SSH_ALIAS" "source ~/.cargo/env 2>/dev/null; source ~/.local/bin/env 2>/dev/null; cd $ALPASIM_DIR && UV_LINK_MODE=copy uv sync --extra all --extra transfuser" 2>&1 | tail -3

# Step 16: Verify alpasim_wizard imports
echo ""
echo "Step 16: Verifying alpasim_wizard imports..."
WIZARD_OK=$(ssh "$SSH_ALIAS" "source ~/.local/bin/env 2>/dev/null; cd $ALPASIM_DIR && uv run python -c 'import alpasim_wizard; print(\"ok\")' 2>/dev/null" || echo "FAIL")
[[ "$WIZARD_OK" != "ok" ]] && { echo "ERROR: alpasim_wizard import failed."; exit 1; }
echo "  ok   alpasim_wizard imports."

# Step 17: Create AlpaSim mount-point directories
echo ""
echo "Step 17: Creating AlpaSim mount directories..."
ssh "$SSH_ALIAS" "mkdir -p $ALPASIM_DIR/data/drivers"

# Step 18: Pre-build alpasim-base:0.70.0 SERIALLY (avoid parallel-build disk blowup)
echo ""
echo "Step 18: Pre-building alpasim-base:0.70.0 image (serial, 10-15 min)..."
ssh "$SSH_ALIAS" "cd $ALPASIM_DIR && sudo docker build -t alpasim-base:0.70.0 -f Dockerfile . 2>&1 | tail -5"

# Step 19: Verify the base image exists
echo ""
echo "Step 19: Verifying alpasim-base:0.70.0 image..."
IMAGE_OK=$(ssh "$SSH_ALIAS" "sudo docker images alpasim-base:0.70.0 -q 2>/dev/null" | head -1)
[[ -z "$IMAGE_OK" ]] && { echo "ERROR: alpasim-base:0.70.0 image not built."; exit 1; }
echo "  ok   alpasim-base:0.70.0 image built (id $IMAGE_OK)."

echo ""
echo "==> Bootstrap complete."
echo ""
echo "  GPU:           $GPU_INFO"
echo "  AlpaSim path:  $ALPASIM_DIR"
echo "  Project path:  $PROJECT_DIR"
echo "  Docker root:   $DATA_ROOT/docker"
echo ""
echo "Disk free on $DATA_ROOT:"
ssh "$SSH_ALIAS" "df -h $DATA_ROOT | tail -1"
echo ""
echo "Ready to run scenarios:"
echo "  bash documents/scripts/run-scenario.sh <scenario-name>"
