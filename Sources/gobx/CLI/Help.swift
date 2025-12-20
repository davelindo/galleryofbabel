import Foundation

let gobxHelpText = """
gobx - native high-performance scorer for Gallery of Babel (macOS/Accelerate)

Usage:
  gobx score <seed> [--backend cpu|mps] [--batch <n>] [--json]
  gobx selftest [--golden <path>] [--write-golden] [--count <n>] [--limit <n>] [--tolerance <x>]
  gobx bench-mps [--seconds <s>] [--warmup <s>] [--warmup-batches <n>] [--reps <n>] [--batches <csv>] [--size <n>] [--gpu-util] [--gpu-interval-ms <n>] [--inflight <n>] [--opt 0|1] [--log-dir <path>] [--json]
  gobx calibrate-mps [--batch <n>] [--scan <n>] [--top <n>] [--quantile <q>] [--opt 0|1] [--out <path>] [--force]
  gobx explore [--count <n>] [--endless] [--start <seed>] [--threads <n>]
              [--batch <n>] [--backend cpu|mps|all] [--top <n>]
              [--submit] [--top-unique-users] [--min-score <x>] [--refresh-every <sec>]
              [--report-every <sec>] [--ui|--no-ui]
              [--mem-guard-gb <n>] [--mem-guard-frac <f>] [--mem-guard-every <sec>]
              [--mps-margin <x>] [--mps-margin-auto] [--mps-inflight <n>] [--mps-reinit-every <sec>]
              [--mps-batch-auto] [--mps-batch-min <n>] [--mps-batch-max <n>] [--mps-batch-tune-every <sec>]
              [--seed-mode state|stride] [--state <path>] [--state-reset]
              [--state-write-every <sec>] [--claim <n>]

Notes:
  - In endless mode, prints live seeds/s + running avg score (split per backend for `--backend all`).
  - When stdout is a TTY, `explore` uses an htop-style live UI by default (disable with `--no-ui`).
  - When Metal is available, `explore` defaults to `--backend mps --submit --mps-batch-auto --mps-margin-auto --top-unique-users`.
  - When Metal is unavailable, `explore` defaults to `--backend cpu --submit --top-unique-users`.
  - `--backend mps` uses a GPU approximation (peakiness uses geometric mean instead of median).
  - When `--submit` is enabled, approximate candidates (MPS) are verified with the CPU scorer before submitting.
  - `--top-unique-users` uses the unique-user top list for threshold refreshes.
  - `--mps-margin-auto` samples high MPS scores on CPU to adapt the MPS margin during a run.
  - `--mps-batch-auto` adapts MPS batch size for throughput (use min/max/tune-every to control bounds).
  - `--mem-guard-gb` / `--mem-guard-frac` cap process memory (phys_footprint) and stop before Jetsam; default 0.8x phys mem on MPS; set to 0 to disable.
  - Config/profile is read from `~/.config/gallery-of-babel/config.json`.
  - If no profile is configured, `explore` falls back to the default author profile for submissions.
  - Set `GOBX_NO_CRASH_REPORTER=1` to disable fatal-signal backtraces.
"""
