from __future__ import annotations

import argparse
import os
from pathlib import Path

from .dashboard import parse_samples, render_all_assets
from .main import _connect


def _load_samples(limit: int) -> list:
    conn = _connect()
    rows = conn.execute(
        """
        SELECT received_at, app_version, total_rate, total_count, elapsed_sec
        FROM runs
        ORDER BY received_at DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    conn.close()
    return parse_samples(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate dashboard PNG assets.")
    parser.add_argument(
        "--output",
        default="stats-collection/generated",
        help="Output directory for generated PNGs.",
    )
    parser.add_argument("--limit", type=int, default=5000, help="Max runs to load.")
    args = parser.parse_args()

    samples = _load_samples(args.limit)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    assets = render_all_assets(samples)
    for name, data in assets.items():
        path = output_dir / name
        path.write_bytes(data)
        print(f"Wrote {path}")


if __name__ == "__main__":
    main()
