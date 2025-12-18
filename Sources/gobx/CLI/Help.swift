import Foundation

let gobxHelpText = """
gobx - native high-performance scorer for Gallery of Babel (macOS/Accelerate)

Usage:
  gobx score <seed> [--backend cpu|mps] [--batch <n>] [--json]
  gobx selftest [--golden <path>] [--write-golden] [--count <n>] [--limit <n>] [--tolerance <x>]
  gobx bench-mps [--seconds <s>] [--warmup <s>] [--warmup-batches <n>] [--reps <n>] [--batches <csv>] [--inflight <n>] [--opt 0|1] [--log-dir <path>] [--json]
  gobx calibrate-mps [--batch <n>] [--scan <n>] [--top <n>] [--quantile <q>] [--opt 0|1] [--out <path>] [--force]
  gobx calibrate-mps-stage1 [--stage1-size <n>] [--batch <n>] [--scan <n>] [--top <n>] [--quantile <q>] [--opt 0|1] [--out <path>] [--force]
  gobx explore --count <n> [--endless] [--start <seed>] [--threads <n>]
              [--batch <n>] [--backend cpu|mps|all] [--top <n>]
              [--submit] [--min-score <x>] [--refresh-every <sec>]
              [--report-every <sec>] [--mps-margin <x>] [--mps-inflight <n>] [--mps-reinit-every <sec>]
              [--mps-two-stage] [--mps-stage1-size <n>] [--mps-stage1-margin <x>] [--mps-stage2-batch <n>]
              [--seed-mode state|stride] [--state <path>] [--state-reset]
              [--state-write-every <sec>] [--claim <n>]

Notes:
  - In endless mode, prints live seeds/s + running avg score (split per backend for `--backend all`).
  - `--backend mps` uses a GPU approximation (peakiness uses geometric mean instead of median).
  - When `--submit` is enabled, MPS candidates are verified with the CPU scorer before submitting.
  - Config/profile is read from `~/.config/gallery-of-babel/config.json`.
  - Set `GOBX_NO_CRASH_REPORTER=1` to disable fatal-signal backtraces.
"""

