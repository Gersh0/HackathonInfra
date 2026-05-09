# 🏗️ System Architecture

## Overview

High-performance YouTube clone designed to handle **1000-3000 concurrent users** on a single server using modern containerized architecture.

## Design Principles

1. **Performance First**: Every component optimized for high concurrency
2. **Separation of Concerns**: Clear boundaries between services
3. **Async by Default**: Non-blocking operations throughout the stack
4. **Horizontal Readiness**: Designed to scale across multiple servers
5. **Observability**: Full tracing, metrics, and logging

## Component Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│     Client      │    │   Grafana       │    │  Load Testing   │
│   (Browser)     │    │  (Monitoring)   │    │     (k6)        │
└─────────┬───────┘    └─────────┬───────┘    └─────────┬───────┘
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 │
                    ┌─────────────────┐
                    │      Nginx      │  ← Reverse Proxy + Static Files
                    │   (Port 80)     │
                    └─────────┬───────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        │                     │                     │
┌───────▼─────────┐  ┌────────▼────────┐  ┌─────────▼──────┐
│   Frontend      │  │    Backend      │  │   Grafana      │
│  React + Vite   │  │ FastAPI + Gunicorn │   Dashboards   │
│   (Port 5173)   │  │   (Port 8000)   │  │  (Port 3000)   │
└─────────────────┘  └────────┬────────┘  └────────────────┘
                              │
                    ┌─────────┼─────────┐
                    │                   │
            ┌───────▼──────┐   ┌────────▼────────┐
            │ PostgreSQL   │   │     Redis       │
            │ (Database)   │   │ (Cache + Queue) │
            │ (Port 5432)  │   │  (Port 6379)    │
            └──────────────┘   └─────────┬───────┘
                                        │
                              ┌─────────▼──────┐
                              │   RQ Workers   │
                              │ (Background)   │
                              └────────────────┘
```

## Request Flow Patterns

### 1. **Page Load (Frontend)**
```
User → Nginx → Frontend (React SPA)
                 ↓
              API Calls → Nginx → Backend → PostgreSQL/Redis
```

### 2. **API Request**  
```
User → Nginx (/api/*) → Backend → Auth Check → Business Logic
                                      ↓
                                  Database/Cache
                                      ↓
                                  JSON Response
```

### 3. **Video Streaming**
```
User → Nginx (/api/videos/123/stream) → Backend (Auth) → X-Accel-Redirect
                                                               ↓
                      User ← Nginx (Direct File Serve) ←──────┘
```

### 4. **Background Processing**
```
User Upload → Backend → Queue Job → Redis → RQ Worker → File Processing
                ↓                                            ↓
          202 Response                                   Update Database
```

## Performance Characteristics

### **Target Metrics**
- **Concurrent Users**: 1000-3000
- **Response Time**: p95 < 500ms, p99 < 1s
- **Throughput**: 1000+ RPS
- **Availability**: 99.9% uptime
- **Resource Usage**: Single 4-core, 8GB server

### **Optimization Techniques**

**Database (PostgreSQL)**
- Connection pooling managed by the SQLAlchemy engine; refer to backend database configuration for current runtime settings
- Strategic indexing on hot columns
- SQLAlchemy ORM-based data access
- Query optimization for N+1 prevention

**Caching (Redis)**
- Cache-aside pattern with TTL jitter
- Stampede protection via soft locks
- Background cache warming
- Session and rate limit storage

**Media Delivery**
- Nginx X-Accel-Redirect (zero backend bandwidth)
- HTTP range request support
- Static file optimization

**Background Processing**
- RQ job queues: video_processing, analytics, default
- Async task offloading
- Retry logic with exponential backoff

**Frontend Optimization**
- Code splitting and lazy loading
- React query for data caching
- Vite build optimization

## Scalability Patterns

### **Vertical Scaling** (Single Server)
```
Current: 2 workers → Target: 4-8 workers
Memory: 8GB → 16-32GB  
CPU: 4 cores → 8-16 cores
Storage: SSD for database + media
```

### **Horizontal Scaling** (Multi-Server)
```
Load Balancer
    ├── App Server 1 (nginx + backend)
    ├── App Server 2 (nginx + backend)  
    └── App Server N (nginx + backend)
            ↓
    Shared Database (RDS/PostgreSQL cluster)
            ↓  
    Shared Cache (Redis cluster/ElastiCache)
            ↓
    Shared Storage (S3/EFS for media files)
```

## Security Model

**Authentication Flow**
```
Login → Backend → JWT Token (120min) → Redis Session → Rate Limiting
```

**Authorization Patterns**
- JWT token validation on all protected endpoints
- Role-based access control (future)
- Rate limiting per IP and per user
- Input validation and sanitization

**Data Protection**
- Environment variable secrets
- Database connection encryption
- CORS policy enforcement
- Media file access control via backend

## Monitoring and Observability

**Metrics Collection**
```
Backend → OpenTelemetry → OTLP Collector → Prometheus → Grafana
         → Structured Logs → JSON Format
```

**Key Metrics Tracked**
- Request rate, latency (p50/p95/p99), error rate
- Database connection pool usage
- Redis cache hit/miss ratios
- Queue depth and processing time
- Container resource usage (CPU/Memory)

**Alerting Thresholds**
- API error rate > 2% for 5 minutes
- p95 latency > 400ms for 5 minutes
- Queue depth > 100 for 10 minutes
- Database connections > 80% pool size

## Data Model

**Core Entities**
```sql
users (id, username, email, created_at, avatar_url)
videos (id, title, description, views, uploader_id, created_at, stream_path, thumbnail_path)
comments (id, video_id, user_id, content, created_at)
subscriptions (id, follower_id, creator_id, created_at)
likes (id, video_id, user_id, created_at) -- unique constraint on (video_id, user_id)
```

**Indexing Strategy**
```sql
-- High-frequency queries
CREATE INDEX ON videos (created_at DESC);
CREATE INDEX ON videos (uploader_id, created_at DESC);
CREATE INDEX ON videos (views DESC);
CREATE INDEX ON comments (video_id, created_at DESC);
CREATE INDEX ON subscriptions (follower_id, created_at DESC);
CREATE INDEX ON subscriptions (creator_id);
CREATE UNIQUE INDEX ON likes (video_id, user_id);
```

## Deployment Models

### **Development**
- Docker Compose with dev profile
- Hot reload enabled
- Direct port access
- Debug logging

### **Production (Local)**
- Docker Compose with prod profile  
- Nginx proxy layer
- Production logging
- Optional observability

### **Production (AWS)**
- Terraform-managed EC2 instance
- Cloud-init automated setup
- Security groups and networking
- Monitoring and alerting

## Known Limitations

**Single Points of Failure**
- Database (PostgreSQL) - single instance
- Cache (Redis) - single instance
- File storage - local disk only

**Resource Constraints**
- Memory usage grows with concurrent connections
- Disk I/O limited by server hardware
- Network bandwidth shared across all services

**Scaling Bottlenecks**
- Database connection pool exhaustion
- Hot row contention (video views)
- File storage capacity
- Single-server CPU/memory limits

## Future Improvements

**Performance**
- Database read replicas
- CDN for media delivery
- Redis cluster for high availability
- Horizontal scaling architecture

**Features**
- Real-time notifications (WebSocket)
- Video transcoding pipeline
- Content recommendation system
- Advanced analytics and reporting

**Operations**
- Automated backup and recovery
- Blue-green deployment
- A/B testing framework
- Enhanced monitoring and alerting