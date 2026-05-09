# Observability Assets

This directory contains ready-to-import observability artifacts for Sprint 2:

- Prometheus alert rules: `observability/prometheus/alert_rules.yml`
- Prometheus scrape config example: `observability/prometheus/prometheus.example.yml`
- Grafana dashboard JSON: `observability/grafana/dashboards/api-overview.json`

## Grafana Access via Nginx Proxy

Grafana is now served through the nginx proxy at `/grafana/` instead of a direct port.

**Access URLs:**
- **Production / default local setup**: `http://localhost/grafana/`
- **Development** (if nginx disabled): no direct host URL is available by default because Grafana is only exposed to the Docker network (`expose: 3000`), not published to the host
- **Direct access option**: add a Grafana port mapping in your Compose override if you want browser access at `http://localhost:3000`

**Default credentials:** `admin` / `admin` (change `GRAFANA_ADMIN_PASSWORD` in `.env` for production)

**Configuration details:**
- Grafana runs with `GF_SERVER_SERVE_FROM_SUB_PATH=true`
- Root URL automatically set to `http://localhost/grafana`
- All static assets and WebSocket connections routed through nginx
- WebSocket support enabled for live dashboard features

**If Grafana doesn't load:**
1. Ensure you're using `--profile observe` when starting services
2. Check that nginx is running: `docker compose ps nginx`
3. Try accessing with trailing slash: `http://localhost/grafana/`
4. Check nginx logs: `docker compose logs nginx`

## Dashboard coverage

The dashboard includes saturation and SLO-focused panels for:

- API error rate (5xx ratio)
- API p95 latency
- Requests per second (RPS)
- Queue depth by queue name
- In-flight requests

## Alert coverage

The alert rules include:

- `APIHighErrorRate` (critical): 5xx rate above 2% for 5m
- `APIHighP95Latency` (warning): p95 latency above 400ms for 5m
- `QueueBacklogHigh` (warning): queue depth above 100 for 10m
- `APIInFlightRequestsHigh` (warning): in-flight requests above 200 for 5m

## Prometheus Configuration

The Prometheus instance automatically scrapes these targets:

**Internal scrape targets:**
- Backend API metrics: `http://backend:8000/metrics`
- cAdvisor container metrics: `http://cadvisor:8080/metrics`
- Prometheus self-monitoring: `http://localhost:9090/metrics`

**External access (for custom Prometheus instances):**
- Backend via nginx: `http://localhost/api/metrics` 
- Backend direct: `http://localhost:8000/metrics` (dev profile only)

**Alert rules:**
Pre-configured alerts in `prometheus/alert_rules.yml`:
- `APIHighErrorRate`: 5xx rate > 2% for 5 minutes
- `APIHighP95Latency`: p95 latency > 400ms for 5 minutes  
- `QueueBacklogHigh`: queue depth > 100 for 10 minutes
- `APIInFlightRequestsHigh`: concurrent requests > 200 for 5 minutes

**To customize alerting:**
1. Edit `observability/prometheus/alert_rules.yml`
2. Configure alert manager in `observability/prometheus/prometheus.yml`
3. Restart services: `docker compose --profile observe restart prometheus`

## Grafana Dashboard Import

**Automatic import (recommended):**
Dashboards are automatically provisioned when starting with `--profile observe`.

**Manual import:**
1. Access Grafana at `http://localhost/grafana/`
2. Login with `admin` / `admin` (or your `GRAFANA_ADMIN_PASSWORD`)
3. Go to Dashboards → Import
4. Upload `observability/grafana/dashboards/api-overview.json`
5. Select "Prometheus" as datasource

**Available dashboards:**
- **API Overview**: Request rates, latency, error rates, queue depths
- **Infrastructure**: Container CPU/memory, disk usage, network I/O

**Datasources (auto-configured):**
- **Prometheus**: Metrics and alerting
- **Tempo**: Distributed tracing via OpenTelemetry
