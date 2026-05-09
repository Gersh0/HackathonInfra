from collections.abc import Callable

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from sqlalchemy.engine import Engine

REQUESTS_TOTAL = Counter(
    "api_requests_total",
    "Total number of HTTP requests",
    ["method", "path", "status_code"],
)
REQUEST_LATENCY_SECONDS = Histogram(
    "api_request_latency_seconds",
    "HTTP request latency in seconds",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
REQUESTS_IN_PROGRESS = Gauge(
    "api_requests_in_progress",
    "Current number of in-flight HTTP requests",
)
QUEUE_DEPTH = Gauge(
    "queue_depth",
    "Current queue depth by queue name",
    ["queue_name"],
)
DB_POOL_SIZE = Gauge("db_pool_size", "Configured SQLAlchemy pool size")
DB_POOL_CHECKED_IN = Gauge("db_pool_checked_in", "Connections currently checked in")
DB_POOL_CHECKED_OUT = Gauge("db_pool_checked_out", "Connections currently checked out")
DB_POOL_OVERFLOW = Gauge("db_pool_overflow", "Connections currently in overflow")


def observe_request(method: str, path: str, status_code: int, duration_seconds: float) -> None:
    REQUESTS_TOTAL.labels(method=method, path=path, status_code=str(status_code)).inc()
    REQUEST_LATENCY_SECONDS.labels(method=method, path=path).observe(duration_seconds)


def track_in_progress() -> Callable[[], None]:
    REQUESTS_IN_PROGRESS.inc()

    def done() -> None:
        REQUESTS_IN_PROGRESS.dec()

    return done


def observe_queue_depths(depths: dict[str, int]) -> None:
    for queue_name, depth in depths.items():
        QUEUE_DEPTH.labels(queue_name=queue_name).set(depth)


def observe_db_pool(engine: Engine) -> None:
    pool = getattr(engine, "pool", None)
    if pool is None:
        return

    if hasattr(pool, "size"):
        DB_POOL_SIZE.set(pool.size())
    if hasattr(pool, "checkedin"):
        DB_POOL_CHECKED_IN.set(pool.checkedin())
    if hasattr(pool, "checkedout"):
        DB_POOL_CHECKED_OUT.set(pool.checkedout())
    if hasattr(pool, "overflow"):
        DB_POOL_OVERFLOW.set(pool.overflow())


def metrics_payload() -> tuple[bytes, str]:
    return generate_latest(), CONTENT_TYPE_LATEST
