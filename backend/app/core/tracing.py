from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter

from app.core.settings import settings

_tracing_configured = False


def configure_tracing(app, engine) -> None:
    global _tracing_configured

    if _tracing_configured or not settings.tracing_enabled:
        return

    resource = Resource.create({"service.name": settings.tracing_service_name})
    provider = TracerProvider(resource=resource)

    if settings.tracing_otlp_endpoint:
        otlp_exporter = OTLPSpanExporter(endpoint=settings.tracing_otlp_endpoint)
        provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
    else:
        provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))

    trace.set_tracer_provider(provider)
    FastAPIInstrumentor.instrument_app(app)
    SQLAlchemyInstrumentor().instrument(engine=engine)
    RedisInstrumentor().instrument()

    _tracing_configured = True
