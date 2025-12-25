# gobx

**gobx** is a high-performance, native explorer and scorer for the [Gallery of Babel](https://www.echohive.ai/gallery-of-babel/).

This repo is a small exploration into using a fused Metal GPU proxy for brute-force search over a deterministic noise field, based on the scoring ideas described in:
- https://www.echohive.ai/gallery-of-babel/how-it-works

It features a dual-backend architecture:
*   **CPU:** Reference implementation using Apple's **Accelerate** framework (vDSP/LinearAlgebra) for maximum precision.
*   **Metal GPU:** High-throughput approximation on Apple Silicon. The fused 2x2 pyramid kernel keeps intermediate tiles in threadgroup memory (no full image writes), enabling up to ~20x speedups vs the older FFT proxy on supported hardware.

## Features

*   **Hybrid Mining:** Uses the Metal GPU for wide-net searching and CPU for precise verification.
*   **Adaptive GPU Tuning:** Auto-tunes batch size and margin for throughput and accuracy.
*   **Automated Calibration:** Tools to tune GPU scoring thresholds against CPU ground truth for your specific hardware.
*   **State Management:** Tracks exploration progress to prevent re-scanning the same seed ranges.
*   **Live Submission:** Automatically submits qualifying seeds to the Gallery of Babel API.

## Performance

| Hardware | Device ID | Backend | Throughput | Power | Efficiency | Best Score | Rarity |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **MacBook Pro M4 Pro (24GB)** | `Mac16,8` | Metal (GPU) | **2.04M seeds/s** | ~40W | **183.4M seeds/Wh** | `-8.504137` | ~1 in 5.99e11 |

*Efficiency calculated as (Seeds per Second * 3600) / Watts. Rarity estimated from /api/stats total generations at time of run (score ≥ current #1).*

> **Note:** Please open a PR to add your hardware and findings!

## Requirements

*   **OS:** macOS 14.0+ (Requires Metal and Accelerate frameworks).
*   **Hardware:** Apple Silicon (M1/M2/M3/M4) recommended for Metal performance.
*   **Build:** Swift 6.0+.

## Installation

Clone the repository and build using Swift Package Manager:

```bash
git clone https://github.com/davelindo/galleryofbabel.git
cd galleryofbabel
swift build -c release
cp .build/release/gobx /usr/local/bin/
```

If you're running in a sandboxed environment (or just want a clean build output), use:

```bash
make build
```

If SwiftPM sandboxing is blocked on your system, add:

```bash
make build SWIFT_BUILD_FLAGS=--disable-sandbox
```

## Configuration

To submit findings to the backend, create a configuration file at `~/.config/gallery-of-babel/config.json`:

```json
{
  "baseUrl": "https://www.echohive.ai",
  "profile": {
    "id": "YOUR_UUID_HERE",
    "name": "YourDisplayname",
    "xProfile": "yourhandle"
  }
}
```

If no profile is configured, `gobx explore` will fall back to the default author profile for submissions.

## Usage

### 1. Exploration (Mining)
The main command to search for seeds. By default, it uses the GPU backend when available and submits results.

```bash
# Run endless exploration (uses GPU if available, otherwise CPU)
gobx explore --endless

# Force CPU-only
gobx explore --backend cpu --endless

# Run with a specific batch size (Metal GPU)
gobx explore --backend mps --gpu-backend metal --batch 192 --mps-inflight 2
```

Defaults:
- Metal available: `--backend mps --gpu-backend metal --submit --mps-batch-auto --mps-inflight-auto --mps-margin-auto --top-unique-users`
- Metal unavailable: `--backend cpu --submit --top-unique-users`

### 2. Scoring a Specific Seed
Verify the score of a known seed.

```bash
# CPU (Exact)
gobx score 123456789

# GPU (Approximate)
gobx score 123456789 --backend mps --gpu-backend metal
```

### 3. Calibration
Because floating-point operations differ between CPU and GPU, the Metal scorer is an approximation. Calibration ensures you don't discard valid seeds or submit invalid ones.

**Step 1: Calibrate Metal vs CPU**
Scans random seeds to find the scoring delta between GPU and CPU.
```bash
gobx calibrate-metal --scan 1000000
```

*These commands write calibration files to `~/.config/gallery-of-babel/` which `gobx explore` automatically loads.*

### 4. Benchmarking
Measure your hardware's throughput.

```bash
# Benchmark Metal performance across various batch sizes
gobx bench-metal --seconds 5 --warmup 2
```

### 5. Self-Test
Verify that the CPU scorer matches the canonical "golden" implementation.

```bash
gobx selftest
```

## Architecture

*   **Mulberry32:** The deterministic PRNG used to generate the noise field.
*   **Scoring Metrics:**
    *   **Alpha:** Slope of the log-log power spectrum (expected ~3.0).
    *   **Peakiness:** Ratio of max power to median power in the mid-frequency ring.
    *   **Flatness:** Spectral flatness measure.
    *   **Neighbor Correlation:** Pixel-wise correlation to ensure spatial coherence.
*   **Seed Space:** Iterates through a 64-bit seed space using a coprime stride pattern to maximize coverage.

## Troubleshooting

*   **Crashes:** If `gobx` crashes, a custom crash reporter will print a backtrace. Set `GOBX_NO_CRASH_REPORTER=1` to disable this.
*   **Calibration Warnings:** If you see "No valid Metal calibration found", run the calibration commands listed above.
*   **State Reset:** If you want to restart exploration from a random location, pass `--state-reset` to the explore command.
