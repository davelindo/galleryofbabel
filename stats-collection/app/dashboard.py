from __future__ import annotations

import io
from dataclasses import dataclass
from datetime import datetime
from statistics import median
from typing import Iterable, Sequence

import matplotlib
import matplotlib.dates as mdates
import matplotlib.pyplot as plt


matplotlib.use("Agg")


@dataclass(frozen=True)
class RunSample:
    received_at: datetime
    app_version: str
    total_rate: float
    total_count: int
    elapsed_sec: float


@dataclass(frozen=True)
class DashboardSummary:
    estimated_rate: float
    sample_count: int
    total_runs: int
    unique_versions: int
    last_received_at: datetime | None


def _format_rate(rate: float) -> str:
    if rate >= 1_000_000_000:
        return f"{rate / 1_000_000_000:.2f}B/s"
    if rate >= 1_000_000:
        return f"{rate / 1_000_000:.2f}M/s"
    if rate >= 1_000:
        return f"{rate / 1_000:.1f}k/s"
    return f"{rate:.1f}/s"


def _format_number(value: float) -> str:
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}k"
    return f"{value:.0f}"


def build_summary(samples: Sequence[RunSample]) -> DashboardSummary:
    if not samples:
        return DashboardSummary(
            estimated_rate=0.0,
            sample_count=0,
            total_runs=0,
            unique_versions=0,
            last_received_at=None,
        )
    recent = samples[-50:] if len(samples) > 50 else samples
    rates = [sample.total_rate for sample in recent]
    estimated = median(rates)
    last_received = samples[-1].received_at
    versions = {sample.app_version for sample in samples if sample.app_version}
    return DashboardSummary(
        estimated_rate=estimated,
        sample_count=len(recent),
        total_runs=len(samples),
        unique_versions=len(versions),
        last_received_at=last_received,
    )


def _render_placeholder(title: str, message: str) -> bytes:
    fig, ax = plt.subplots(figsize=(8, 3))
    ax.set_axis_off()
    ax.text(0.5, 0.6, title, ha="center", va="center", fontsize=18, weight="bold")
    ax.text(0.5, 0.4, message, ha="center", va="center", fontsize=12, color="#555")
    buffer = io.BytesIO()
    fig.tight_layout()
    fig.savefig(buffer, format="png", dpi=160, bbox_inches="tight")
    plt.close(fig)
    buffer.seek(0)
    return buffer.read()


def render_total_rate_card(summary: DashboardSummary) -> bytes:
    if summary.sample_count == 0:
        return _render_placeholder("Estimated total rate", "No data yet")
    fig, ax = plt.subplots(figsize=(6, 3))
    ax.set_axis_off()
    ax.text(
        0.5,
        0.62,
        _format_rate(summary.estimated_rate),
        ha="center",
        va="center",
        fontsize=32,
        weight="bold",
        color="#0f172a",
    )
    ax.text(
        0.5,
        0.38,
        f"Median of last {summary.sample_count} runs",
        ha="center",
        va="center",
        fontsize=12,
        color="#475569",
    )
    buffer = io.BytesIO()
    fig.tight_layout()
    fig.savefig(buffer, format="png", dpi=160, bbox_inches="tight")
    plt.close(fig)
    buffer.seek(0)
    return buffer.read()


def _app_version_boundaries(samples: Sequence[RunSample]) -> list[tuple[datetime, str]]:
    boundaries: list[tuple[datetime, str]] = []
    last_version = None
    for sample in samples:
        if sample.app_version != last_version:
            boundaries.append((sample.received_at, sample.app_version))
            last_version = sample.app_version
    return boundaries


def render_performance_over_time(samples: Sequence[RunSample]) -> bytes:
    if not samples:
        return _render_placeholder("Performance over time", "No data yet")
    times = [sample.received_at for sample in samples]
    rates = [sample.total_rate for sample in samples]
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.plot(times, rates, color="#2563eb", linewidth=1.4)
    ax.scatter(times[-1], rates[-1], color="#1d4ed8", s=24, zorder=3)
    ax.set_title("Total rate over time")
    ax.set_ylabel("Total rate (/s)")
    ax.grid(alpha=0.2)
    ax.yaxis.set_major_formatter(lambda val, _: _format_number(val))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %d"))
    fig.autofmt_xdate()
    boundaries = _app_version_boundaries(samples)
    for idx, (ts, version) in enumerate(boundaries):
        ax.axvline(ts, color="#94a3b8", linestyle="--", linewidth=0.7, alpha=0.6)
        if idx >= len(boundaries) - 4:
            ax.text(
                ts,
                max(rates) * 0.95,
                version[:10],
                rotation=90,
                fontsize=8,
                color="#64748b",
                va="top",
            )
    buffer = io.BytesIO()
    fig.tight_layout()
    fig.savefig(buffer, format="png", dpi=160)
    plt.close(fig)
    buffer.seek(0)
    return buffer.read()


def _summarize_by_version(samples: Sequence[RunSample]) -> list[tuple[str, float]]:
    buckets: dict[str, list[float]] = {}
    for sample in samples:
        if not sample.app_version:
            continue
        buckets.setdefault(sample.app_version, []).append(sample.total_rate)
    ordered_versions: list[str] = []
    seen: set[str] = set()
    for sample in samples:
        if sample.app_version and sample.app_version not in seen:
            ordered_versions.append(sample.app_version)
            seen.add(sample.app_version)
    summary = []
    for version in ordered_versions:
        rates = buckets.get(version, [])
        if rates:
            summary.append((version, median(rates)))
    return summary


def render_performance_by_version(samples: Sequence[RunSample]) -> bytes:
    if not samples:
        return _render_placeholder("Performance by app version", "No data yet")
    summary = _summarize_by_version(samples)
    if not summary:
        return _render_placeholder("Performance by app version", "No version data yet")
    trimmed = summary[-12:]
    versions = [item[0] for item in trimmed]
    medians = [item[1] for item in trimmed]
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.bar(range(len(medians)), medians, color="#22c55e")
    ax.set_title("Median total rate by app version")
    ax.set_ylabel("Median total rate (/s)")
    ax.set_xticks(range(len(versions)))
    ax.set_xticklabels([v[:10] for v in versions], rotation=30, ha="right", fontsize=8)
    ax.yaxis.set_major_formatter(lambda val, _: _format_number(val))
    ax.grid(axis="y", alpha=0.2)
    buffer = io.BytesIO()
    fig.tight_layout()
    fig.savefig(buffer, format="png", dpi=160)
    plt.close(fig)
    buffer.seek(0)
    return buffer.read()


def render_all_assets(samples: Sequence[RunSample]) -> dict[str, bytes]:
    summary = build_summary(samples)
    return {
        "total_rate.png": render_total_rate_card(summary),
        "perf_over_time.png": render_performance_over_time(samples),
        "perf_by_version.png": render_performance_by_version(samples),
    }


def parse_samples(rows: Iterable[tuple[str, str, float, int, float]]) -> list[RunSample]:
    samples = []
    for received_at, app_version, total_rate, total_count, elapsed_sec in rows:
        samples.append(
            RunSample(
                received_at=datetime.fromisoformat(received_at),
                app_version=app_version or "unknown",
                total_rate=total_rate,
                total_count=total_count,
                elapsed_sec=elapsed_sec,
            )
        )
    samples.sort(key=lambda s: s.received_at)
    return samples
