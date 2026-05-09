import asyncio
import logging
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response

from app.async_jobs.dispatcher import job_dispatcher
from app.api.routes.auth import router as auth_router
from app.api.routes.users import router as users_router
from app.api.routes.videos import router as videos_router
from app.core.cache import async_cache
from app.core.database import engine
from app.core.logging import configure_json_logging
from app.core.metrics import metrics_payload, observe_db_pool, observe_queue_depths, observe_request, track_in_progress
from app.core.settings import settings
from app.core.tracing import configure_tracing
from app.services.video_service import _analytics_flush_loop

configure_json_logging(settings.log_level)
startup_logger = logging.getLogger("app.startup")
request_logger = logging.getLogger("app.requests")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    task = asyncio.create_task(_analytics_flush_loop(async_cache))
    startup_logger.info("analytics flusher started")
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="YouTube Clone API", lifespan=lifespan)
configure_tracing(app, engine)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_allow_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _parse_perf_ms(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        parsed = float(value)
    except ValueError:
        return None
    return parsed if parsed >= 0 else None


def error_response(
    request: Request,
    *,
    status_code: int,
    code: str,
    message: str,
    details: object | None = None,
) -> JSONResponse:
    request_id = request.headers.get("x-request-id")
    error_payload: dict[str, object] = {
        "code": code,
        "message": message,
    }

    if details is not None:
        error_payload["details"] = details

    payload: dict[str, object] = {
        "error": error_payload,
        "path": request.url.path,
    }

    if request_id:
        payload["request_id"] = request_id

    return JSONResponse(status_code=status_code, content=payload)


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    detail = exc.detail
    if isinstance(detail, dict):
        message = str(detail.get("message", "Request failed"))
        code = str(detail.get("code", "http_error"))
        details = detail.get("details")
    else:
        message = str(detail)
        code = "http_error"
        details = None

    return error_response(
        request,
        status_code=exc.status_code,
        code=code,
        message=message,
        details=details,
    )


@app.exception_handler(StarletteHTTPException)
async def starlette_http_exception_handler(request: Request, exc: StarletteHTTPException):
    detail = exc.detail if exc.detail is not None else "Request failed"
    return error_response(
        request,
        status_code=exc.status_code,
        code="http_error",
        message=str(detail),
    )


@app.exception_handler(RequestValidationError)
async def request_validation_exception_handler(request: Request, exc: RequestValidationError):
    return error_response(
        request,
        status_code=422,
        code="validation_error",
        message="Request validation failed",
        details=exc.errors(),
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    request_logger.exception("unhandled_exception", extra={"path": request.url.path})
    return error_response(
        request,
        status_code=500,
        code="internal_server_error",
        message="Internal server error",
    )


@app.middleware("http")
async def request_size_guard(request: Request, call_next):
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            length_value = int(content_length)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid Content-Length header")

        max_body_bytes = settings.max_request_body_bytes
        if request.url.path == "/videos/upload":
            max_body_bytes = (
                settings.max_video_upload_bytes
                + settings.max_thumbnail_upload_bytes
                + settings.max_multipart_overhead_bytes
            )

        if length_value > max_body_bytes:
            raise HTTPException(status_code=413, detail="Request payload too large")

    return await call_next(request)


@app.middleware("http")
async def request_logging(request: Request, call_next):
    request_id = request.headers.get("x-request-id", str(uuid.uuid4()))
    started_at = time.perf_counter()
    client_ip = request.client.host if request.client else "unknown"

    try:
        response = await call_next(request)
    except Exception:
        duration_ms = round((time.perf_counter() - started_at) * 1000, 2)
        request_logger.exception(
            "request_failed",
            extra={
                "request_id": request_id,
                "method": request.method,
                "path": request.url.path,
                "status_code": 500,
                "duration_ms": duration_ms,
                "client_ip": client_ip,
            },
        )
        raise

    duration_ms = round((time.perf_counter() - started_at) * 1000, 2)
    request_logger.info(
        "request_completed",
        extra={
            "request_id": request_id,
            "method": request.method,
            "path": request.url.path,
            "status_code": response.status_code,
            "duration_ms": duration_ms,
            "client_ip": client_ip,
        },
    )
    response.headers["x-request-id"] = request_id
    return response


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    done = track_in_progress()
    started_at = time.perf_counter()
    route = request.scope.get("route")
    path_label = getattr(route, "path", request.url.path)

    try:
        response = await call_next(request)
    except Exception:
        duration_seconds = time.perf_counter() - started_at
        observe_request(request.method, path_label, 500, duration_seconds)
        done()
        raise

    duration_seconds = time.perf_counter() - started_at
    observe_request(request.method, path_label, response.status_code, duration_seconds)
    done()
    return response


@app.middleware("http")
async def request_timing_middleware(request: Request, call_next):
    started_at = time.perf_counter()
    response = await call_next(request)
    total_ms = (time.perf_counter() - started_at) * 1000

    route_total_ms = _parse_perf_ms(response.headers.get("x-perf-total-ms"))
    if route_total_ms is not None:
        residual_ms = max(0.0, total_ms - route_total_ms)
        response.headers["x-perf-request-ms"] = f"{total_ms:.2f}"
        response.headers["x-perf-queueish-ms"] = f"{residual_ms:.2f}"
    elif request.query_params.get("perf") == "1":
        response.headers["x-perf-request-ms"] = f"{total_ms:.2f}"

    return response


@app.get("/health")
async def health_check():
    return {"status": "ok"}


@app.get("/health/queues")
async def queue_health_check():
    return {"status": "ok", "queue_depths": job_dispatcher.queue_depths()}


@app.get("/metrics")
async def metrics():
    observe_queue_depths(job_dispatcher.queue_depths())
    observe_db_pool(engine)
    payload, content_type = metrics_payload()
    return Response(content=payload, media_type=content_type)


app.include_router(videos_router)
app.include_router(users_router)
app.include_router(auth_router)
