# gobx

**gobx** is a high-performance, native explorer and scorer for the [Gallery of Babel](https://www.echohive.ai/gallery-of-babel/).

It is a native Swift application built for Apple Silicon, using a dual-backend architecture to maximize throughput while maintaining scoring precision. It achieves state-of-the-art search speeds by using a custom fused Metal compute kernel to approximate image statistics without performing a full FFT on the GPU.

## Features

*   **Hybrid Search Architecture**
    *   **GPU (Metal):** Uses a fused "Pyramid Proxy" kernel (`MetalPyramidScorer`) to estimate variance and spectral properties at multi-million seeds/s on M-series hardware.
    *   **CPU (Accelerate):** Uses vDSP/LinearAlgebra for exact verification of promising candidates found by the GPU.
*   **Adaptive Tuning**
    *   **Batch & Inflight:** Automatically adjusts batch sizes and command buffer saturation to maximize GPU utilization.
    *   **Dynamic Margins/Shift:** Continuously tunes the GPU/CPU scoring margin to balance false positives vs false negatives.
*   **Resilience**
    *   **Memory Guards:** Monitors `phys_footprint` and stops before hitting macOS memory limits (Jetsam).
    *   **State Management:** Journaled progress tracking (`gobx-seed-state.json`) allows pausing and resuming without re-scanning seeds.
*   **Live Dashboard:** Interactive, htop-style terminal UI showing real-time throughput and tuning metrics.
*   **Automated Submission:** Automatically submits qualifying seeds to the Gallery of Babel API.
*   **Optional Stats:** Opt-in, anonymized performance metrics (every 60s and at exit).

## Performance

| Date | Hardware | Device ID | Backend | Throughput | Power | Efficiency |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 2025-12-26 | **MacBook Pro M4 Pro (24GB)** | `Mac16,8` | Metal (GPU) | **4,779,931 seeds/s** | ~46W | **374.1M seeds/Wh** |
| n/a | **MacBook Pro M4 Pro (24GB)** | `Mac16,8` | Metal (GPU) | **2.04M seeds/s** | ~40W | **183.4M seeds/Wh** |

*Efficiency calculated as (Seeds per Second * 3600) / Watts. Throughput depends on verification rate and adaptive margin/shift.*

> **Note:** Please open a PR to add your hardware and findings.

## Results

This approach reached the #1 spot on the Gallery of Babel leaderboard.

## Requirements

*   **OS:** macOS 14.0+ (Sonoma or Sequoia).
*   **Hardware:** Apple Silicon (M1/M2/M3/M4/M5) strongly recommended.
*   **Build:** Swift 6.0+.
*   **Tooling:** Xcode Command Line Tools (or full Xcode) for Swift/SwiftPM (`xcode-select --install`).

## Installation

### 1. Build from Source

```bash
git clone https://github.com/davelindo/galleryofbabel.git
cd galleryofbabel
make build
```

The binary will be located at `.build/release/gobx`. You can copy this to your path:

```bash
cp .build/release/gobx /usr/local/bin/
```

If SwiftPM sandboxing is blocked on your system, add:

```bash
make build SWIFT_BUILD_FLAGS=--disable-sandbox
```

### 2. First Run and Setup

Run the tool in exploration mode. It will detect a missing configuration and launch an interactive wizard to set up your profile and optional telemetry, then automatically train proxy weights and run calibration if needed.

```bash
gobx explore
```

By default, `gobx explore` runs endlessly until you stop it. Use `--count` for a finite run.

Example wizard run:

```text
No config found at /Users/you/.config/gallery-of-babel/config.json. Run first-time setup now? [Y/n]
Configure submission profile now? [Y/n]
Profile id [user_abcd1234_xyz987654]:
Display name [Cosmic-Explorer-AB12]:
X handle (optional, without @):
Share anonymized performance stats? [y/N]
Write config to /Users/you/.config/gallery-of-babel/config.json? [Y/n]
Wrote config to /Users/you/.config/gallery-of-babel/config.json
Training proxy weights (first-time setup)...
Running Metal calibration (first-time setup)...
```

## Configuration

Configuration is stored in `~/.config/gallery-of-babel/config.json`.

```json
{
  "profile": {
    "id": "user_...",
    "name": "YourDisplayname",
    "xProfile": "yourhandle"
  },
  "stats": {
    "enabled": false,
    "url": "https://gobx-stats.davelindon.me/ingest"
  }
}
```

*   **Profile:** Used for leaderboard submissions.
*   **Stats:** Optional opt-in for anonymized performance telemetry.

## Usage

### Exploration (Mining)
The primary mode is `explore`. It defaults to using the Metal backend with adaptive batching.

```bash
# Run indefinitely (Ctrl+C to stop)
gobx explore

# Run for a specific number of seeds
gobx explore --count 10000000
```

**Common Flags:**
*   `--endless`: Explicitly run forever (default if count is omitted).
*   `--no-ui`: Disable the dashboard (useful for logging to files).
*   `--report-every <sec>`: Status line cadence in non-UI mode.
*   `--start <seed>`: Start from a specific seed and reset state.
*   `--setup`: Run the interactive setup without exiting `explore`.

### Benchmarking
Measure raw throughput without verification overhead.

```bash
# Sweep common batch sizes
gobx bench-metal

# Benchmark specific parameters
gobx bench-metal --size 128 --tg 192 --batches 256,512 --seconds 10
```

### Calibration
The Metal proxy provides an approximation of the score. Calibration scans random seeds to determine the statistical error margin between the GPU and CPU scorers, ensuring you do not miss high-scoring seeds.

```bash
gobx calibrate-metal
gobx calibrate-metal --force
```

*Note: `gobx explore` loads these calibration values automatically and runs calibration on first run when needed.*

### Verification
Check the exact score of a specific seed using the CPU reference implementation.

```bash
gobx score 123456789
```

### Proxy Training and Logs
Train proxy weights either from fresh CPU samples or from a `proxy-log` capture.

```bash
# Self-contained training (generates its own CPU samples)
gobx train-proxy

# Capture training data (features + CPU scores)
gobx proxy-log --n 500000

# Train from the proxy-log output
gobx train-proxy-log
```

### Stats Dashboard

The hosted stats service publishes PNGs generated by the `/stats` dashboard. These visuals reflect **only opt-in** runs (users must explicitly enable stats collection), so they are not comprehensive of all gobx usage.

![Estimated total rate](https://gobx-stats.davelindon.me/stats/assets/total_rate.png)
![Performance over time](https://gobx-stats.davelindon.me/stats/assets/perf_over_time.png)
![Performance by version](https://gobx-stats.davelindon.me/stats/assets/perf_by_version.png)

## Architecture details

### The Scoring Function
The tool evaluates 128x128 monochrome images generated from a 64-bit seed using Mulberry32 RNG. The score is a weighted sum of:
1.  **Alpha:** The slope of the power spectrum (log-log), targeting -3.0.
2.  **Peakiness:** Ratio of max power to geometric mean in the mid-frequency ring.
3.  **Flatness:** Spectral flatness measure.
4.  **Neighbor Correlation:** Pixel-wise spatial coherence.

### The Metal Pyramid Proxy
Calculating a full 2D FFT for every seed is expensive. `gobx` uses a custom Metal kernel (`PyramidProxy.metal`) that:
1.  Generates the noise in registers.
2.  Computes neighbor correlation on the fly.
3.  Performs a 2x2 block reduction (pooling) iteratively to approximate spectral energy at different spatial frequencies.
4.  Estimates the final score using learned linear weights.

Candidates passing the GPU threshold are sent to the CPU for exact scoring.

## Troubleshooting

*   **"No valid Metal calibration found"**: Run `gobx calibrate-metal`.
*   **Jetsam / Out of Memory**: Reduce other GPU/CPU load and restart; gobx attempts to exit before hitting system limits.
*   **Crashes**: The tool includes a crash reporter that prints backtraces on SIGSEGV/SIGBUS. Set `GOBX_NO_CRASH_REPORTER=1` to disable it.
