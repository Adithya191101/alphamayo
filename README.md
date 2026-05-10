# Alpamayo Explore

A reproducible guide to running **NVIDIA Alpamayo 1.5** (a 10-billion-parameter reasoning Vision-Language-Action model for autonomous driving) inside **AlpaSim** (NVIDIA's closed-loop driving simulator) and reading the chain-of-causation traces it produces.

Inspired by Boris Ivanovic's keynote at the Berkeley Robotics and AI Conference, April 29, 2026.

---

## What you get

For each driving scene you run, AlpaSim with the Alpamayo 1.5 driver produces:

- An **mp4 video** of the simulated drive
- A **`rollout.asl`** binary log with per-step **chain-of-causation reasoning** ("Nudge left due to a vehicle encroaching from the right curb", "Stop to yield to the pedestrian in the crosswalk ahead", etc.)
- A **trajectory prediction chart** showing ego history + predicted future
- Eval metrics (collision, off-road, plan deviation, progress)

A composite layout combining all of the above:

```
+----------------------------+----------------------------+
|                            |  t = 4.0s                  |
|   BEV map     |  metrics   |  Reasoning:                |
|               |            |  ['Nudge left due to ...]  |
|----------------------------|----------------------------|
| Camera (front-wide)        |                            |
|  + green/yellow trajectory |   Trajectory Prediction    |
|  + Command: STRAIGHT       |   (history + prediction)   |
|                            |                            |
+----------------------------+----------------------------+
```

### Demo runs

**Scenario 1 — Construction zone** (NVIDIA's published showcase scene from their developer blog Figures 1, 2, 11)

![Construction zone demo](documents/showcase/scenario_construction/demo.gif)

Reasoning chains include red-light stops, pedestrian yields, lane-narrowing merge planning, lateral nudges around stopped vehicles. [(metrics)](documents/showcase/scenario_construction/metrics.txt) · [(full-quality mp4)](documents/showcase/scenario_construction/demo.mp4)

---

**Scenario 2 — Urban intersection with pedestrian crossing** (curated from the NuRec 26.02 release by filtering for `layout=intersection,pedestrian_crossing` + `vrus=true` + daytime/dry)

![Pedestrian crossing demo](documents/showcase/scenario_pedestrian/demo.gif)

Reasoning chains include stop-sign detection, pedestrian yielding, sign-conditional turns ("Turn right because the one-way sign indicates right only"), bollard/median obstacle reasoning. [(metrics)](documents/showcase/scenario_pedestrian/metrics.txt) · [(full-quality mp4)](documents/showcase/scenario_pedestrian/demo.mp4)

---

Demo videos are produced by `documents/scripts/run-scenario.sh` plus the post-render compositor described below.

---

## What does NOT work

Before you spend money: **RunPod is not a viable host for AlpaSim.** Their pods are non-privileged containers and the host seccomp profile blocks the `unshare()` syscall, which Docker needs to register image layers. AlpaSim's docker-compose stack therefore cannot start. RunPod's own docs state: *"Docker Compose is not supported on Pods."* Switching GPU type (A100 vs H100, etc.) does not help — the seccomp restriction is platform-wide. Verified empirically May 2026.

**Hyperstack works** (KVM virtual machines, full root, full Docker). Lambda Labs and Vast.ai's *VM mode* (not container mode) also work, though pricier or with marketplace caveats.

---

## Prerequisites

1. **A Hyperstack account** with a GPU VM you can deploy. A100 80GB ($1.35/hr) or H100 80GB PCIe ($1.90/hr) are both fine. **Boot disk: 300 GB minimum.** AlpaSim's docker-compose service builds expand to ~50 GB; combined with model weights and OS that's tight on a 100 GB disk.

2. **A HuggingFace account** with access granted to the following gated repos (click "Request access" on each):
   - [`nvidia/Alpamayo-1.5-10B`](https://huggingface.co/nvidia/Alpamayo-1.5-10B) — the VLA model itself
   - [`nvidia/Cosmos-Reason2-8B`](https://huggingface.co/nvidia/Cosmos-Reason2-8B) — the reasoning component used internally by Alpamayo
   - [`nvidia/PhysicalAI-Autonomous-Vehicles-NuRec`](https://huggingface.co/datasets/nvidia/PhysicalAI-Autonomous-Vehicles-NuRec) — the driving scene dataset (USDZ files)

3. **An SSH keypair** registered both on your local machine and in your Hyperstack account (Settings → Keypairs).

4. **A Mac or Linux workstation** with `git`, `rsync`, `ssh`, and `jq` installed. The provided `mac-setup.sh` checks all four.

---

## Tutorial

### 1. Clone this repo and prepare local config

```bash
git clone <repo-url>
cd alphamayo
cp local.env.template local.env
# Edit local.env and set HF_TOKEN (from huggingface.co/settings/tokens)
```

`local.env.template` is committed; the filled `local.env` is gitignored and never leaves your machine.

### 2. Run the local setup check

```bash
bash documents/scripts/mac-setup.sh
```

This verifies your local toolchain. SSH check will fail until you have a VM (expected).

### 3. Deploy a GPU VM on Hyperstack

In the Hyperstack console:

1. **Settings → Keypairs**: import your SSH public key (typically `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`)
2. **Compute → Deploy VM**:
   - GPU: **A100 80GB PCIe** or **H100 80GB PCIe**
   - Image: **Ubuntu Server 22.04 LTS**
   - Boot disk: **300 GB** (this is critical — 100 GB will fail)
   - Keypair: the one you just uploaded
   - Toggle "Enable SSH access" (auto-creates a port-22 firewall rule)
3. Wait until status is `ACTIVE`, then copy the public IP.

### 4. Configure SSH on your Mac

Add to `~/.ssh/config`:

```
Host alpamayo-vm
    HostName <your-vm-public-ip>
    User ubuntu
    Port 22
    IdentityFile <path-to-your-private-key>
    StrictHostKeyChecking no
```

(`<path-to-your-private-key>` is whatever local file matches the public key you uploaded to Hyperstack — commonly `~/.ssh/id_ed25519` or `~/.ssh/id_rsa`.)



Update `local.env` with the new `POD_HOST` and `POD_USER=ubuntu`.

Test:
```bash
ssh alpamayo-vm echo "connected"
```

### 5. Bootstrap the VM

```bash
bash documents/scripts/vm-bootstrap.sh
```

This is fully automated and takes ~25 minutes. It performs, in order:

1. Disable `apt-daily.timer` and `apt-daily-upgrade.timer` (otherwise `unattended-upgrades` holds the dpkg lock for 25+ minutes on a fresh Ubuntu cloud image)
2. Symlink `/workspace` to `/ephemeral` (the 750 GB local SSD Hyperstack provides on GPU instances; `/var/lib/containerd` will also be relocated there)
3. Verify the GPU and CUDA driver
4. Pre-configure `/etc/docker/daemon.json` to use `/ephemeral/docker` as data root
5. Install Docker
6. Install NVIDIA Container Toolkit and verify `docker run --gpus all` works
7. Log in to HuggingFace using `HF_TOKEN`
8. Install `uv` (Python package manager) and the Rust toolchain (needed for AlpaSim's `utils_rs` crate)
9. `git clone` AlpaSim from `github.com/NVlabs/alpasim`
10. Run `setup_local_env.sh` and `uv sync --extra all --extra transfuser`
11. Verify `alpasim_wizard` imports
12. Pre-build the `alpasim-base:0.70.0` Docker image **serially** (parallel builds blow up disk usage)

### 6. Run a scenario

The default tutorial scene downloads automatically:

```bash
bash documents/scripts/run-scenario.sh scenario_01
```

To pick a specific NuRec scene (e.g., NVIDIA's published showcase construction-zone scene):

```bash
ssh alpamayo-vm "source ~/.bashrc && cd /workspace/alpasim && \
  uv run alpasim_wizard \
    deploy=local topology=1gpu driver=alpamayo1_5 \
    'scenes.scene_ids=[clipgt-02eadd92-02f1-46d8-86fe-a9e338fed0b6]' \
    eval.video.generate_combined_video=true \
    'eval.video.video_layouts=[DEFAULT,REASONING_OVERLAY]' \
    wizard.log_dir=/workspace/alphamayo/documents/outputs/scenario_construction"
```

Each scenario takes ~7-10 minutes once the bootstrap is warm.

### 7. Pull results to your Mac

```bash
bash documents/scripts/pull-results.sh scenario_construction
```

Outputs land in `documents/outputs/<scenario_name>/`:
- `rollouts/.../rollout.asl` — binary chain-of-causation log
- `rollouts/.../*_camera_front_wide_120fov_default.mp4` — DEFAULT layout video
- `rollouts/.../*_camera_front_wide_120fov_reasoning_overlay.mp4` — REASONING_OVERLAY layout video
- `aggregate/metrics_results.txt` — eval metrics
- `aggregate/videos/all/00_all_clips_fast.mp4` — sped-up overview

---

## Cherry-picking interesting scenes

The default tutorial scene is a benign lead-vehicle-following clip. For richer reasoning, filter the NuRec dataset's per-scene `labels.json` files (available for the `26.02_release` batch onward).

```bash
# On the pod
hf download nvidia/PhysicalAI-Autonomous-Vehicles-NuRec \
  --repo-type dataset --include "sample_set/26.02_release/**/labels.json" \
  --local-dir /workspace/nurec_meta
```

Each `labels.json` contains:
- `behavior`: `driving_straight`, `stop`, `left_turn`, `right_turn`, `left_lane_change`, `right_lane_change`, `reverse`
- `layout`: `straight_road`, `intersection`, `construction_zone`, `pedestrian_crossing`, `roundabout`, `underpass`, `bridge`, `parking_lot`, `ramp`, `railway_crossing`
- `weather`, `surface_conditions`, `lighting`, `traffic_density`, `road_types`, `vrus`

For visually-clean and reasoning-rich scenes, filter for `lighting=daytime` + `surface_conditions=dry` + interesting layouts (construction_zone, intersection + pedestrian_crossing, etc.).

**Important:** the 26.02 scenes are NOT in AlpaSim's default `data/scenes/sim_scenes.csv`. Provide a custom CSV via Hydra override:

```bash
# Create in writable workspace, NOT in the alpasim repo
cat > /workspace/extra_scenes.csv <<EOF
uuid,scene_id,nre_version_string,path,last_modified,artifact_repository,hf_revision
<internal-uuid>,clipgt-<folder-uuid>,26.02,sample_set/26.02_release/<folder-uuid>/<folder-uuid>.usdz,2026-05-09 00:00:00,huggingface,26.02
EOF

uv run alpasim_wizard ... \
  'scenes.scenes_csv=[/workspace/alpasim/data/scenes/sim_scenes.csv,/workspace/extra_scenes.csv]' \
  'scenes.scene_ids=[clipgt-<folder-uuid>]'
```

Note: the `uuid` field must be the **internal** UUID of the USDZ file (different from the folder name in the path). The wizard reports the expected internal UUID in its error message if you guess wrong; copy it and re-run.

---

## Producing a LinkedIn-ready composite video

The two AlpaSim videos (`*_default.mp4` and `*_reasoning_overlay.mp4`) can be composited into a single 1920×1080 LinkedIn-friendly video showing all info at once: BEV map + metrics + camera + Command + Reasoning banner + Trajectory chart.

The compositor uses ffmpeg (installed in step 5):

```bash
# On the VM, with default and reasoning_overlay videos available
ffmpeg -y -i <DEFAULT.mp4> -i <REASONING_OVERLAY.mp4> \
  -filter_complex "
    [0:v]scale=960:1080:force_original_aspect_ratio=disable[left];
    [1:v]crop=1100:175:0:0,scale=960:160[banner];
    [1:v]crop=1080:1080:1920:0,scale=920:920,pad=960:920:20:0:color=#0a0a0a[chart];
    [banner][chart]vstack=inputs=2,pad=960:1080:0:0:color=#0a0a0a[right];
    [left][right]hstack=inputs=2
  " -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p output.mp4
```

---

## Cost estimate

| Item | Approx. cost |
|---|---|
| Hyperstack H100 80GB PCIe, ~3 hr session (bootstrap + 1-2 scenarios) | ~$5.70 |
| Subsequent scenarios on same warm session | ~$0.30 each |
| 300 GB boot disk while running | included |
| HuggingFace dataset / model download | free |
| Network egress | free on Hyperstack |

**Total to reproduce this project: ~$6-10** depending on how many scenarios you run.

**Stop the VM between sessions.** Hyperstack charges per minute; idle running is wasted. The bootstrap state lives on `/ephemeral` which is wiped when the VM stops, so a fresh run-through after a stop takes another ~25 minutes.

---

## Repository structure

```
alphamayo/
├── README.md                  ← this file
├── .gitignore
├── documents/
│   ├── scripts/
│   │   ├── mac-setup.sh           verify local toolchain
│   │   ├── vm-bootstrap.sh        one-shot VM provisioning
│   │   ├── run-scenario.sh        run a single scenario
│   │   └── pull-results.sh        rsync results to local
│   ├── showcase/                  curated demo videos + metrics (committed)
│   │   ├── scenario_construction/
│   │   └── scenario_pedestrian/
│   ├── outputs/                   raw simulation outputs from a real run
│   │                              (mp4s, configs, parquets, logs are committed;
│   │                               rollout.asl binaries are gitignored — too large)
│   └── notebooks/
```

The repo intentionally does not contain `local.env`, `vault/`, or other personal notes/config — those stay private to each user.

---

## Lessons learned (so you don't repeat them)

- **RunPod doesn't work** (covered above) — verify the seccomp profile of any container-style host before committing.
- **100 GB boot disk is too small.** AlpaSim's `docker compose up --build` builds 4-5 service images in parallel, each adding ~3 GB to a writable overlay layer. Combined peak disk use exceeds 100 GB. Use 300 GB or relocate Docker storage to a larger volume (the bootstrap script does the latter).
- **Pre-build `alpasim-base:0.70.0` once, serially.** The wizard's parallel build of the same image across services is what blows up disk; building it once first puts it in the cache and the wizard skips the rebuild.
- **Three HuggingFace gated repos must be approved** before the first scenario run. The Cosmos one is easy to forget — Alpamayo loads it internally as a reasoning component, and the failure surfaces only when the driver container starts up.
- **NuRec scene UUIDs**: the folder name on HF is *not* the scene's internal UUID. The wizard validates the internal one against the CSV's `uuid` column. Use the wizard's error message to discover the right value.
- **Disable `apt-daily.timer` and `apt-daily-upgrade.timer` first** on a fresh Ubuntu cloud image, otherwise `unattended-upgrades` holds the dpkg lock for 25+ minutes the first time you try to apt-install anything.

---

## References

- [NVlabs/alpasim](https://github.com/NVlabs/alpasim) — AlpaSim simulator
- [NVIDIA Developer Blog: Building AVs that Reason with Alpamayo](https://developer.nvidia.com/blog/building-autonomous-vehicles-that-reason-with-nvidia-alpamayo/)
- [Alpamayo 1.5 model card](https://huggingface.co/nvidia/Alpamayo-1.5-10B)
- [PhysicalAI Autonomous-Vehicles NuRec dataset](https://huggingface.co/datasets/nvidia/PhysicalAI-Autonomous-Vehicles-NuRec)
- Boris Ivanovic, Berkeley Robotics and AI Conference, April 29, 2026 (keynote)

---

## License

This repo contains tooling, scripts, and documentation only. The AlpaSim source code, Alpamayo model weights, and NuRec dataset are NVIDIA's and governed by their respective licenses (see linked pages above). Nothing in this repo redistributes any NVIDIA artifact.

Tooling here is MIT-licensed.
