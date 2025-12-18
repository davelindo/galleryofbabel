# gobx

**gobx** is a high-performance, native explorer and scorer for the [Gallery of Babel](https://www.echohive.ai/gallery-of-babel/).

This repo is a small exploration into using **Metal Performance Shaders (MPSGraph)** for brute-force search over a deterministic noise field, based on the scoring ideas described in:
- https://www.echohive.ai/gallery-of-babel/how-it-works

It features a dual-backend architecture:
*   **CPU:** Reference implementation using Apple's **Accelerate** framework (vDSP/LinearAlgebra) for maximum precision.
*   **MPS:** Massively parallel approximation using **Metal Performance Shaders** for high-throughput exploration on Apple Silicon GPUs.

## Features

*   **Hybrid Mining:** Uses GPU (MPS) for wide-net searching and CPU for precise verification.
*   **Two-Stage Pipeline:** Optional low-resolution "Stage 1" (e.g., 64x64) pre-filtering on GPU to discard uninteresting seeds quickly.
*   **Automated Calibration:** Tools to tune GPU scoring thresholds against CPU ground truth for your specific hardware.
*   **State Management:** Tracks exploration progress to prevent re-scanning the same seed ranges.
*   **Live Submission:** Automatically submits qualifying seeds to the Gallery of Babel API.

## Requirements

*   **OS:** macOS 14.0+ (Requires Metal and Accelerate frameworks).
*   **Hardware:** Apple Silicon (M1/M2/M3) recommended for MPS performance.
*   **Build:** Swift 6.0+.

## Installation

Clone the repository and build using Swift Package Manager:

```bash
git clone https://github.com/your-repo/gobx.git
cd gobx
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

## Usage

### 1. Exploration (Mining)
The main command to search for seeds. By default, it uses the CPU. To enable the GPU:

```bash
# Run endless exploration using Metal (MPS) backend
gobx explore --backend mps --endless --submit

# Run with a specific thread count and batch size
gobx explore --backend mps --batch 64 --mps-inflight 3 --submit
```

**Advanced Optimization (Two-Stage):**
This renders small thumbnails (64x64) on the GPU first. Only promising candidates are rendered at full size (128x128).

```bash
gobx explore --backend mps --mps-two-stage --mps-stage1-size 64 --submit
```

### 2. Scoring a Specific Seed
Verify the score of a known seed.

```bash
# CPU (Exact)
gobx score 123456789

# GPU (Approximate)
gobx score 123456789 --backend mps
```

### 3. Calibration
Because floating-point operations differ between CPU and GPU, the GPU scorer is an approximation. Calibration ensures you don't discard valid seeds or submit invalid ones.

**Step 1: Calibrate MPS vs CPU**
Scans random seeds to find the scoring delta between GPU and CPU.
```bash
gobx calibrate-mps --scan 1000000
```

**Step 2: Calibrate Stage 1 vs Stage 2 (If using two-stage)**
```bash
gobx calibrate-mps-stage1 --stage1-size 64 --scan 1000000
```

*These commands write calibration files to `~/.config/gallery-of-babel/` which `gobx explore` automatically loads.*

### 4. Benchmarking
Measure your hardware's throughput.

```bash
# Benchmark MPS performance across various batch sizes
gobx bench-mps --seconds 5 --warmup 2
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
*   **Calibration Warnings:** If you see "No valid MPS calibration found", run the calibration commands listed above.
*   **State Reset:** If you want to restart exploration from a random location, pass `--state-reset` to the explore command.
