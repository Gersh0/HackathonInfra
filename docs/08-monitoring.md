# Monitoring

The application exposes Prometheus metrics and ships a Grafana dashboard for real-time observability.

---

## Metrics Endpoint

The backend exposes metrics at `/metrics` in Prometheus text format:

```
http://localhost/api/metrics        (via Nginx in prod)
http://localhost:8000/metrics       (direct in dev)
```

### Available metrics

| Metric | Type | Description |
|--------|------|-------------|
| `http_requests_total` | Counter | Requests by method, path, status code |
| `http_request_duration_seconds` | Histogram | Request latency (p50, p95, p99) |
| `http_requests_in_flight` | Gauge | Concurrent in-flight requests |
| `rq_queue_depth` | Gauge | Job queue depth by queue name |
| `db_pool_size` | Gauge | SQLAlchemy pool: total connections |
| `db_pool_checked_in` | Gauge | SQLAlchemy pool: idle connections |
| `db_pool_overflow` | Gauge | SQLAlchemy pool: overflow connections |

---

## Starting the Monitoring Stack

The monitoring stack (Prometheus + Grafana) runs via a separate Docker Compose profile:

```bash
# Linux / macOS / WSL
docker compose -f docker-compose.monitoring.yml up -d

# Windows PowerShell
docker compose -f docker-compose.monitoring.yml up -d
```

| Service | URL |
|---------|-----|
| Grafana | `http://localhost:3000` |
| Prometheus | `http://localhost:9090` |

Default Grafana credentials: `admin` / `admin` (change on first login).

---

## Prometheus Configuration

The scrape config lives in `observability/prometheus/`.

### Quick setup

Copy the example config:

```bash
cp observability/prometheus/prometheus.example.yml observability/prometheus/prometheus.yml
```

Edit `prometheus.yml` to set the scrape target. For local Docker Desktop:

```yaml
scrape_configs:
  - job_name: youtube_clone
    static_configs:
      - targets: ['host.docker.internal:80']
    metrics_path: /api/metrics
```

For a remote server (EC2), replace `host.docker.internal:80` with the server's IP or domain.

### Mounting alert rules

`observability/prometheus/alert_rules.yml` contains pre-configured alert rules. Reference it in `prometheus.yml`:

```yaml
rule_files:
  - /etc/prometheus/alert_rules.yml
```

---

## Alert Rules

Defined in `observability/prometheus/alert_rules.yml`:

| Alert | Severity | Condition |
|-------|----------|-----------|
| `APIHighErrorRate` | critical | 5xx error rate > 2% for 5 minutes |
| `APIHighP95Latency` | warning | p95 latency > 400ms for 5 minutes |
| `QueueBacklogHigh` | warning | Queue depth > 100 jobs for 10 minutes |
| `APIInFlightRequestsHigh` | warning | In-flight requests > 200 for 5 minutes |

---

## Grafana Dashboard

The dashboard JSON is at `observability/grafana/dashboards/api-overview.json`.

### Import the dashboard

1. Open Grafana at `http://localhost:3000`
2. Click the **+** icon → **Import**
3. Click **Upload JSON file**
4. Select `observability/grafana/dashboards/api-overview.json`
5. Select your Prometheus datasource
6. Click **Import**

### Dashboard panels

| Panel | What it shows |
|-------|--------------|
| API Error Rate | 5xx responses / total requests (%) |
| API p95 Latency | 95th percentile request duration |
| Requests per Second | Throughput over time |
| Queue Depth | RQ job backlog by queue name |
| In-Flight Requests | Active concurrent requests |

---

## Monitoring a production EC2 deployment

When running on EC2, Prometheus scrapes the application over the network. Configure `prometheus.yml` with the EC2 instance's public IP:

```yaml
scrape_configs:
  - job_name: youtube_clone_prod
    static_configs:
      - targets: ['your-ec2-ip:80']
    metrics_path: /api/metrics
```

For security, restrict the `/api/metrics` endpoint to internal access only by adding an IP allowlist in `nginx/default.conf`:

```nginx
location /api/metrics {
    allow 10.0.0.0/8;        # internal network
    allow 203.0.113.10/32;   # Prometheus server IP
    deny all;
    proxy_pass http://backend:8000/metrics;
}
```

---

## Health Endpoints

The backend exposes two health check endpoints:

```
GET /api/health
→ {"status": "ok"}

GET /api/health/queues
→ {"status": "ok", "queue_depths": {"video_processing": 0, "analytics": 0}}
```

Use these in uptime monitors (UptimeRobot, Pingdom, AWS Route 53 health checks).

---

[← AWS EC2 Deployment](07-deployment-aws.md) · [Wiki Index](index.md) · [Load Testing →](09-load-testing.md)
