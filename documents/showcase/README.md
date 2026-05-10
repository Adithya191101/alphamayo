# Showcase

Composite demo videos and eval metrics from running NVIDIA Alpamayo 1.5 in AlpaSim. Each scene was rendered with both `DEFAULT` and `REASONING_OVERLAY` layouts, then composited into a single 1920×1080 video using ffmpeg (recipe in the top-level `README.md`).

The full simulation outputs (binary `rollout.asl` chain-of-causation logs, raw camera mp4s, parquet telemetry, configs, etc.) are gitignored due to size — only the demo videos and metrics summaries are committed.

---

## Scenes

### `scenario_construction/`

NVIDIA's published showcase scene from the [Alpamayo developer blog](https://developer.nvidia.com/blog/building-autonomous-vehicles-that-reason-with-nvidia-alpamayo/) (Figures 1, 2, 11): a daytime urban drive through a construction zone with a traffic light, slow trucks, parked vehicles encroaching from the curb, and a pedestrian crossing.

- **Scene ID:** `clipgt-02eadd92-02f1-46d8-86fe-a9e338fed0b6`
- **NuRec release:** 25.07
- **Distance driven:** 64.84 m
- **Eval window coverage:** 35% (truncated at offroad event)
- **Outcome:** clean tracking (`dist_to_gt_trajectory: 0.53m max`) but eval flagged `offroad: 1.00`
- **Reasoning richness:** ~30 distinct chains including red-light stops, pedestrian yields, lane-narrowing merge planning, lateral nudges around stopped vehicles

### `scenario_pedestrian/`

26.02-release scene curated by filtering the NuRec `labels.json` index for: urban + intersection + pedestrian crossing + VRUs + clear/cloudy + dry + daytime.

- **Scene ID:** `clipgt-7b186d92-d6f5-4e27-a324-d705d1fad7e1`
- **NuRec release:** 26.02
- **Distance driven:** 69.79 m
- **Eval window coverage:** 91% (much longer engagement than construction)
- **Outcome:** no collisions, `dist_to_gt_trajectory: 2.59m max`
- **Reasoning richness:** stop-sign detection, pedestrian yielding, sign-conditional turns ("Turn right because the one-way sign indicates right only"), bollard/median obstacle reasoning

---

## Files in each subdirectory

| File | What it is |
|---|---|
| `demo.mp4` | 1920×1080 composite: DEFAULT view (BEV map + metrics + camera with green/yellow trajectory + Command banner) on the left, reasoning banner + trajectory prediction chart on the right |
| `metrics.txt` | AlpaSim eval pipeline output — collision/offroad/plan-deviation/progress metrics with aggregation modifiers applied |
| `metrics_plot.png` | Visualization of the metrics across the run |

---

## How these were produced

See the top-level `README.md` for the full reproduction tutorial. Short version:

1. Bootstrap a Hyperstack GPU VM with `documents/scripts/vm-bootstrap.sh`
2. Run a scenario: `bash documents/scripts/run-scenario.sh <name>` (or via `alpasim_wizard` with `scenes.scene_ids=[clipgt-...]`)
3. Pull results: `bash documents/scripts/pull-results.sh <name>`
4. Composite using the ffmpeg recipe in the README
