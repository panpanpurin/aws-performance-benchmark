# CSV processor Prometheus metrics (shared names on EC2/ECS/Lambda for Grafana).
import os
import time
import threading
from typing import Dict, Optional
from contextvars import ContextVar
from prometheus_client import CollectorRegistry, Histogram, Gauge

try:
    import psutil
except ImportError:
    psutil = None

REGISTRY = CollectorRegistry()

# Cold start is recorded only when running on Lambda
IS_LAMBDA = bool(
    os.getenv("AWS_LAMBDA_FUNCTION_NAME")
    or os.getenv("LAMBDA_TASK_ROOT")
    or os.getenv("AWS_EXECUTION_ENV", "").startswith("AWS_Lambda")
)

SERVICE_NAME = os.getenv(
    "SERVICE_NAME",
    "app-instrumented-lambda" if IS_LAMBDA else "app-instrumented-ec2",
)
ENVIRONMENT = os.getenv("ENVIRONMENT", "production")
DEFAULT_LABELS: Dict[str, str] = {
    "service": SERVICE_NAME,
    "environment": ENVIRONMENT,
}

INTERNAL_BUCKETS = [0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 3]
TOTAL_BUCKETS = [0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 3, 5, 8, 12, 20, 30]

app_total_execution_time_seconds = Histogram(
    "app_total_execution_time_seconds",
    "Total time to handle /process (seconds)",
    labelnames=["status", "format", "service", "environment"],
    buckets=TOTAL_BUCKETS,
    registry=REGISTRY,
)
app_internal_processing_time_seconds = Histogram(
    "app_internal_processing_time_seconds",
    "Internal CSV processing time (seconds)",
    labelnames=["status", "service", "environment"],
    buckets=INTERNAL_BUCKETS,
    registry=REGISTRY,
)
app_cold_start_duration_seconds = Histogram(
    "app_cold_start_duration_seconds",
    "Lambda cold start duration (seconds)",
    labelnames=["service", "environment"],
    buckets=TOTAL_BUCKETS,
    registry=REGISTRY,
)

app_cpu_usage_percent = Gauge(
    "app_cpu_usage_percent",
    "Process CPU usage (%)",
    labelnames=["service", "environment"],
    registry=REGISTRY,
)
app_ram_usage_mb = Gauge(
    "app_ram_usage_mb",
    "Process RAM usage (MB)",
    labelnames=["service", "environment"],
    registry=REGISTRY,
)
app_cpu_peak_percent = Gauge(
    "app_cpu_peak_percent",
    "Process CPU usage peak (%) since start",
    labelnames=["service", "environment"],
    registry=REGISTRY,
)
app_ram_peak_mb = Gauge(
    "app_ram_peak_mb",
    "Process RAM usage peak (MB) since start",
    labelnames=["service", "environment"],
    registry=REGISTRY,
)

_IMPORT_T0 = time.perf_counter()
_COLD_RECORDED = False

# Per-request baselines (context-local for concurrent EC2/ECS workers)
_REQ_CPU_T0: ContextVar[Optional[float]] = ContextVar("_REQ_CPU_T0", default=None)
_REQ_WALL_T0: ContextVar[Optional[float]] = ContextVar("_REQ_WALL_T0", default=None)

_PEAK_CPU: Optional[float] = None
_PEAK_RAM: Optional[float] = None
_PEAK_LOCK = threading.Lock()


def maybe_record_cold_start():
    """Record cold start once per runtime (meaningful on Lambda)."""
    global _COLD_RECORDED
    if not IS_LAMBDA or _COLD_RECORDED:
        return
    dt = time.perf_counter() - _IMPORT_T0
    app_cold_start_duration_seconds.labels(**DEFAULT_LABELS).observe(dt)
    _COLD_RECORDED = True


def observe_csv_duration(seconds: float, status: str, fmt: str = "csv"):
    app_total_execution_time_seconds.labels(
        status=status, format=fmt, **DEFAULT_LABELS
    ).observe(seconds)


def observe_csv_internal_duration(seconds: float, status: str):
    app_internal_processing_time_seconds.labels(
        status=status, **DEFAULT_LABELS
    ).observe(seconds)


def begin_cpu_sample():
    """Start per-request CPU baseline (EC2/ECS concurrent-safe via ContextVar)."""
    if not psutil:
        _REQ_CPU_T0.set(None)
        _REQ_WALL_T0.set(None)
        return
    try:
        p = psutil.Process(os.getpid())
        t = p.cpu_times()
        _REQ_CPU_T0.set(float(t.user + t.system))
        _REQ_WALL_T0.set(time.perf_counter())
    except Exception:
        _REQ_CPU_T0.set(None)
        _REQ_WALL_T0.set(None)


def end_cpu_sample_and_record():
    """End per-request CPU/RAM sample and update peaks."""
    global _PEAK_CPU, _PEAK_RAM
    if not psutil:
        return
    try:
        p = psutil.Process(os.getpid())
        mem_mb = p.memory_info().rss / (1024 * 1024)

        cpu_pct = 0.0
        t0 = _REQ_CPU_T0.get()
        w0 = _REQ_WALL_T0.get()
        if t0 is not None and w0 is not None:
            t = p.cpu_times()
            cpu_now = float(t.user + t.system)
            wall_now = time.perf_counter()
            cpu_delta = max(0.0, cpu_now - t0)
            wall_delta = max(1e-6, wall_now - w0)
            # 1 vCPU semantics (t2.micro / ECS limits / Lambda 1024 MB ≈ 1 vCPU)
            cpu_pct = (cpu_delta / wall_delta) * 100.0

        cpu_pct = max(0.0, min(100.0, cpu_pct))

        labels = (DEFAULT_LABELS["service"], DEFAULT_LABELS["environment"])
        app_cpu_usage_percent.labels(*labels).set(cpu_pct)
        app_ram_usage_mb.labels(*labels).set(mem_mb)

        with _PEAK_LOCK:
            if _PEAK_CPU is None or cpu_pct > _PEAK_CPU:
                _PEAK_CPU = cpu_pct
            app_cpu_peak_percent.labels(*labels).set(_PEAK_CPU)

            if _PEAK_RAM is None or mem_mb >= _PEAK_RAM:
                _PEAK_RAM = mem_mb
            app_ram_peak_mb.labels(*labels).set(_PEAK_RAM)
    except Exception:
        pass
