import Foundation

let gobxHelpText = """
gobx - native high-performance scorer for Gallery of Babel (macOS/Accelerate)

Usage:
  gobx --setup
  gobx score <seed> [--backend cpu|mps] [--batch <n>] [--gpu-backend mps|metal] [--json]
  gobx selftest [--golden <path>] [--write-golden] [--count <n>] [--limit <n>] [--tolerance <x>]
  gobx bench-mps [--seconds <s>] [--warmup <s>] [--warmup-batches <n>] [--reps <n>] [--batches <csv>] [--size <n>] [--gpu-util] [--gpu-interval-ms <n>] [--inflight <n>] [--opt 0|1] [--log-dir <path>] [--json]
  gobx bench-metal [--seconds <s>] [--warmup <s>] [--reps <n>] [--batches <csv>] [--size <n>] [--inflight <n>] [--tg <n>] [--cb-dispatches <n>] [--gpu-util] [--gpu-interval-ms <n>] [--gpu-trace <path>]
  gobx calibrate-metal [--force]
  gobx proxy-eval [--n <n>] [--top <n>] [--gate <csv>] [--seed <seed>] [--weights <path>] [--gpu-backend mps|metal] [--report-every <sec>]
  gobx proxy-log [--n <n>] [--out <path>] [--report-every <sec>] [--threads <n>] [--append]
  gobx train-proxy [--n <n>] [--seed <seed>] [--out <path>] [--report-every <sec>] [--threads <n>]
  gobx train-proxy-log [--in <path>] [--out <path>] [--report-every <sec>]
  gobx explore [--count <n>] [--endless] [--start <seed>] [--report-every <sec>] [--gpu-profile dabbling|interested|lets-go|heater] [--submit|--no-submit] [--ui|--no-ui] [--setup]

Notes:
  - In endless mode, prints live seeds/s + running avg score.
  - When stdout is a TTY, `explore` uses an htop-style live UI by default (disable with `--no-ui`).
  - When Metal is available, `explore` uses the Metal GPU proxy with adaptive margin/shift and CPU verification.
  - Approximate candidates (GPU) are verified with the CPU scorer before submitting (use --no-submit to disable).
  - Use --gpu-profile to attenuate GPU throughput on laptops.
  - Config/profile is read from `~/.config/gallery-of-babel/config.json`.
  - If no profile is configured, `explore` falls back to the default author profile for submissions.
  - When no config is found, `explore` offers an interactive first-run setup and runs the bootstrap steps automatically.
  - Use `--setup` to launch the interactive setup even if a config already exists.
  - Use `gobx --setup` to run setup without starting an explore session.
  - Anonymous performance stats are collected only when enabled in config or via `--stats`.
  - Set `GOBX_NO_CRASH_REPORTER=1` to disable fatal-signal backtraces.
"""
