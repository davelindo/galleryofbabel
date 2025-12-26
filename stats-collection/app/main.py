from __future__ import annotations

import json
import os
import re
import sqlite3
from datetime import datetime, timezone
from typing import Literal, Optional

from fastapi import FastAPI, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .dashboard import (
    build_summary,
    parse_samples,
    render_all_assets,
    render_performance_by_version,
    render_performance_over_time,
    render_total_rate_card,
)

DB_PATH = os.environ.get("STATS_DB_PATH", "/data/stats.db")

app = FastAPI(title="Gobx Stats Collector", version="0.1.0")


_HEX_64 = re.compile(r"^[0-9a-fA-F]{64}$")
_RUN_ID = re.compile(r"^[0-9a-fA-F-]{16,64}$")


class RunStats(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schemaVersion: int = Field(..., ge=1)
    runId: str = Field(..., min_length=16, max_length=64)
    deviceId: str = Field(..., min_length=64, max_length=64)
    hwModel: Optional[str] = Field(default=None, max_length=128)
    gpuName: Optional[str] = Field(default=None, max_length=128)
    gpuBackend: Optional[Literal["mps", "metal"]] = None
    backend: Literal["cpu", "mps", "all"]
    osVersion: str = Field(..., max_length=128)
    appVersion: str = Field(..., max_length=64)
    batch: Optional[int] = Field(default=None, ge=1, le=65536)
    inflight: Optional[int] = Field(default=None, ge=1, le=1024)
    batchMin: Optional[int] = Field(default=None, ge=1, le=65536)
    batchMax: Optional[int] = Field(default=None, ge=1, le=65536)
    inflightMin: Optional[int] = Field(default=None, ge=1, le=1024)
    inflightMax: Optional[int] = Field(default=None, ge=1, le=1024)
    autoBatch: bool
    autoInflight: bool
    elapsedSec: float = Field(..., gt=0, le=31_536_000)
    totalCount: int = Field(..., ge=0, le=1_000_000_000_000_000)
    totalRate: float = Field(..., ge=0.0, le=1_000_000_000.0)
    cpuRate: float = Field(..., ge=0.0, le=1_000_000_000.0)
    gpuRate: float = Field(..., ge=0.0, le=1_000_000_000.0)
    cpuAvg: float = Field(..., ge=-1000.0, le=1000.0)
    gpuAvg: float = Field(..., ge=-1000.0, le=1000.0)

    @field_validator("runId")
    @classmethod
    def _validate_run_id(cls, value: str) -> str:
        value = value.strip()
        if not _RUN_ID.match(value):
            raise ValueError("runId must be a uuid-like string")
        return value

    @field_validator("deviceId")
    @classmethod
    def _validate_device_id(cls, value: str) -> str:
        value = value.strip()
        if not _HEX_64.match(value):
            raise ValueError("deviceId must be a 64-char hex string")
        return value.lower()

    @model_validator(mode="after")
    def _validate_ranges(self) -> "RunStats":
        if self.batchMin is not None and self.batchMax is not None:
            if self.batchMin > self.batchMax:
                raise ValueError("batchMin must be <= batchMax")
        if self.inflightMin is not None and self.inflightMax is not None:
            if self.inflightMin > self.inflightMax:
                raise ValueError("inflightMin must be <= inflightMax")
        if self.batch is not None and self.batchMin is not None and self.batch < self.batchMin:
            raise ValueError("batch must be >= batchMin")
        if self.batch is not None and self.batchMax is not None and self.batch > self.batchMax:
            raise ValueError("batch must be <= batchMax")
        if self.inflight is not None and self.inflightMin is not None and self.inflight < self.inflightMin:
            raise ValueError("inflight must be >= inflightMin")
        if self.inflight is not None and self.inflightMax is not None and self.inflight > self.inflightMax:
            raise ValueError("inflight must be <= inflightMax")
        return self


def _connect() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    return conn


def _init_db() -> None:
    conn = _connect()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT NOT NULL,
            device_id TEXT NOT NULL,
            hw_model TEXT,
            gpu_name TEXT,
            gpu_backend TEXT,
            backend TEXT NOT NULL,
            os_version TEXT NOT NULL,
            app_version TEXT NOT NULL,
            batch INTEGER,
            inflight INTEGER,
            elapsed_sec REAL NOT NULL,
            total_count INTEGER NOT NULL,
            total_rate REAL NOT NULL,
            cpu_rate REAL NOT NULL,
            gpu_rate REAL NOT NULL,
            cpu_avg REAL NOT NULL,
            gpu_avg REAL NOT NULL,
            payload_json TEXT NOT NULL
        );
        """
    )
    conn.close()


@app.on_event("startup")
def _startup() -> None:
    _init_db()


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/ingest")
def ingest(payload: RunStats) -> dict:
    received_at = datetime.now(timezone.utc).isoformat()
    conn = _connect()
    conn.execute(
        """
        INSERT INTO runs (
            received_at,
            device_id,
            hw_model,
            gpu_name,
            gpu_backend,
            backend,
            os_version,
            app_version,
            batch,
            inflight,
            elapsed_sec,
            total_count,
            total_rate,
            cpu_rate,
            gpu_rate,
            cpu_avg,
            gpu_avg,
            payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            received_at,
            payload.deviceId,
            payload.hwModel,
            payload.gpuName,
            payload.gpuBackend,
            payload.backend,
            payload.osVersion,
            payload.appVersion,
            payload.batch,
            payload.inflight,
            payload.elapsedSec,
            payload.totalCount,
            payload.totalRate,
            payload.cpuRate,
            payload.gpuRate,
            payload.cpuAvg,
            payload.gpuAvg,
            json.dumps(payload.model_dump(), separators=(",", ":"), sort_keys=True),
        ),
    )
    conn.commit()
    conn.close()
    return {"ok": True}


def _load_samples(limit: int = 5000) -> list:
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


@app.get("/stats")
def stats_dashboard() -> Response:
    samples = _load_samples()
    summary = build_summary(samples)
    last_seen = (
        summary.last_received_at.isoformat() if summary.last_received_at else "No data"
    )
    body = f"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>Gobx Stats Dashboard</title>
        <style>
          body {{
            font-family: system-ui, sans-serif;
            margin: 32px;
            color: #0f172a;
            background: #f8fafc;
          }}
          .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
          }}
          .card {{
            background: white;
            padding: 16px;
            border-radius: 12px;
            box-shadow: 0 1px 3px rgba(15, 23, 42, 0.1);
          }}
          .label {{ color: #64748b; font-size: 12px; text-transform: uppercase; }}
          .value {{ font-size: 20px; font-weight: 600; margin-top: 6px; }}
          img {{ max-width: 100%; height: auto; border-radius: 12px; }}
        </style>
      </head>
      <body>
        <h1>Gobx Stats Dashboard</h1>
        <div class="grid">
          <div class="card">
            <div class="label">Estimated total rate</div>
            <div class="value">{summary.estimated_rate:.1f}/s</div>
            <div class="label">Median of last {summary.sample_count} runs</div>
          </div>
          <div class="card">
            <div class="label">Total runs</div>
            <div class="value">{summary.total_runs}</div>
          </div>
          <div class="card">
            <div class="label">Versions seen</div>
            <div class="value">{summary.unique_versions}</div>
          </div>
          <div class="card">
            <div class="label">Last received</div>
            <div class="value">{last_seen}</div>
          </div>
        </div>
        <div class="card" style="margin-bottom:16px;">
          <h2>Estimated total rate</h2>
          <img src="/stats/assets/total_rate.png" alt="Estimated total rate" />
        </div>
        <div class="card" style="margin-bottom:16px;">
          <h2>Performance over time</h2>
          <img src="/stats/assets/perf_over_time.png" alt="Performance over time" />
        </div>
        <div class="card">
          <h2>Performance by app version</h2>
          <img src="/stats/assets/perf_by_version.png" alt="Performance by version" />
        </div>
      </body>
    </html>
    """
    return Response(content=body, media_type="text/html")


@app.get("/stats/assets/{asset_name}")
def stats_asset(asset_name: str) -> Response:
    samples = _load_samples()
    assets = {
        "total_rate.png": render_total_rate_card(build_summary(samples)),
        "perf_over_time.png": render_performance_over_time(samples),
        "perf_by_version.png": render_performance_by_version(samples),
    }
    image = assets.get(asset_name)
    if image is None:
        return Response(status_code=404)
    return Response(content=image, media_type="image/png")


@app.get("/stats/assets")
def stats_assets_bundle() -> Response:
    samples = _load_samples()
    payload = render_all_assets(samples)
    return Response(content=json.dumps({k: len(v) for k, v in payload.items()}))
