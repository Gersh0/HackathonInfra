# API Reference

Base URL: `http://localhost/api` (production via Nginx) or `http://localhost:8000` (dev direct).

Interactive docs (Swagger UI): `http://localhost/api/docs`

---

## Authentication

Most write endpoints require a JWT bearer token in the `Authorization` header:

```
Authorization: Bearer <access_token>
```

Tokens are obtained from `POST /auth/token` and expire after `JWT_ACCESS_TOKEN_EXP_MINUTES` (default: 120 minutes).

---

## Pagination

All list endpoints return a paginated response:

```json
{
  "items": [...],
  "limit": 20,
  "offset": 0,
  "page_count": 20,
  "total_count": 143,
  "next_offset": 20
}
```

Query parameters:
- `limit` — items per page (default: 20, max: 100)
- `offset` — starting index (default: 0)

`next_offset` is `null` when there are no more pages.

---

## Health

### `GET /health`

No auth required.

```json
{"status": "ok"}
```

### `GET /health/queues`

No auth required. Returns queue depths.

```json
{
  "status": "ok",
  "queue_depths": {
    "video_processing": 0,
    "analytics": 0
  }
}
```

### `GET /metrics`

Prometheus text format. No auth required.

---

## Auth

### `POST /auth/token`

Issue a JWT token for an existing user. Rate-limited.

In production, this endpoint is disabled unless `AUTH_TOKEN_ISSUER_ENABLED=true`.

**Request body:**
```json
{
  "user_id": 42
}
```

**Response `200`:**
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expires_in": 7200
}
```

**Errors:**
- `404` — user not found

---

## Users

### `GET /users`

List users with optional search.

**Query params:**
- `limit` (int, default: 20)
- `offset` (int, default: 0)
- `q` (string, optional) — search by display name

**Response `200`:** paginated `UserResponse[]`

```json
{
  "items": [
    {
      "id": 1,
      "display_name": "Alice",
      "provider": "local",
      "avatar_url": "/uploads/avatars/abc123.jpg",
      "created_at": "2026-03-26T18:00:00Z"
    }
  ],
  "limit": 20,
  "offset": 0,
  "page_count": 1,
  "total_count": 1,
  "next_offset": null
}
```

---

### `POST /users`

Create a new user. Rate-limited. Accepts `multipart/form-data`.

**Form fields:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `display_name` | string | Yes | User's display name |
| `provider` | string | No | Auth provider (default: `local`) |
| `provider_subject` | string | No | Provider's unique ID for the user |
| `email` | string | No | Email address |
| `avatar` | file | No | Avatar image (JPEG, PNG, WebP) |

**Response `200`:** `UserResponse`

---

### `GET /users/providers`

List available auth providers.

**Response `200`:**
```json
{
  "providers": ["local"]
}
```

---

### `POST /users/{user_id}/subscriptions/{creator_id}`

Subscribe to a creator. Requires auth. The token's user ID must match `user_id`.

**Response `200`:**
```json
{
  "follower_id": 1,
  "creator_id": 5
}
```

**Errors:**
- `403` — token user mismatch

---

### `DELETE /users/{user_id}/subscriptions/{creator_id}`

Unsubscribe from a creator. Requires auth.

**Response `200`:**
```json
{"status": "ok"}
```

---

### `GET /users/{user_id}/subscriptions`

List the creator IDs a user is subscribed to.

**Query params:** `limit`, `offset`

**Response `200`:**
```json
{
  "creator_ids": [5, 12, 33]
}
```

---

### `GET /users/{user_id}/feed`

Get videos from subscribed creators, sorted by newest. Paginated.

**Query params:** `limit`, `offset`, `q` (search within feed)

**Response `200`:** paginated `VideoResponse[]`

---

## Videos

### `GET /videos`

List all videos. Cached in Redis.

**Query params:**
- `limit` (int, default: 20)
- `offset` (int, default: 0)
- `q` (string, optional) — search by title or description

**Response `200`:** paginated `VideoResponse[]`

```json
{
  "items": [
    {
      "id": 1,
      "title": "My Video",
      "description": "A cool video",
      "user_id": 3,
      "uploader_name": "Alice",
      "views": 1420,
      "status": "ready",
      "stream_url": "/api/videos/1/stream",
      "thumbnail_url": "/api/videos/1/thumbnail",
      "created_at": "2026-03-26T18:00:00Z"
    }
  ],
  "limit": 20,
  "offset": 0,
  "page_count": 1,
  "total_count": 1,
  "next_offset": null
}
```

---

### `POST /videos/upload`

Upload a new video. **Requires auth.** Rate-limited. Accepts `multipart/form-data`.

**Form fields:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | Yes | Video title |
| `description` | string | No | Video description (default: empty) |
| `file` | file | Yes | Video file (MP4, WebM, etc.) |
| `thumbnail` | file | No | Thumbnail image (JPEG, PNG) |

**Response `200`:** `VideoResponse`

**Errors:**
- `401` — missing or invalid token
- `413` — file too large (max size set by `MAX_VIDEO_UPLOAD_BYTES`)

---

### `GET /videos/{video_id}`

Get video details. Increments the view counter. Cached with 2-second max-age + 5-second stale-while-revalidate.

**Response `200`:** `VideoResponse`

**Errors:**
- `404` — video not found

---

### `GET /videos/{video_id}/stream`

Stream the video file. Nginx serves bytes via `X-Accel-Redirect`. No auth required (access is public once you have the video ID).

**Response:** video bytes (Content-Type: video/mp4 or detected MIME type)

---

### `GET /videos/{video_id}/thumbnail`

Get the video thumbnail. Nginx serves bytes via `X-Accel-Redirect`.

**Response:** image bytes

**Errors:**
- `404` — no thumbnail exists for this video

---

### `DELETE /videos/{video_id}`

Delete a video. **Requires auth.** Only the video's owner can delete it. Rate-limited.

**Response `200`:**
```json
{"status": "ok"}
```

**Errors:**
- `401` — not authenticated
- `403` — not the video owner

---

### `GET /videos/{video_id}/comments`

List comments for a video. Paginated.

**Query params:** `limit`, `offset`

**Response `200`:** paginated `CommentResponse[]`

```json
{
  "items": [
    {
      "id": 1,
      "video_id": 5,
      "author": "Alice",
      "content": "Great video!",
      "created_at": "2026-04-01T10:00:00Z"
    }
  ],
  ...
}
```

---

### `POST /videos/{video_id}/comments`

Post a comment. **Requires auth.** Rate-limited.

**Request body:**
```json
{
  "content": "Great video!"
}
```

**Response `200`:** `CommentResponse`

---

### `GET /videos/{video_id}/recommended`

Get recommended videos (related content, excluding current video).

**Query params:** `limit` (default: 8)

**Response `200`:** paginated `VideoResponse[]`

---

### `GET /videos/{video_id}/redis-probe`

Diagnostic endpoint. Measures Redis latency for the view-count increment, view-count read, and analytics write for a given video. No auth required.

**Query params:**
- `perf` (bool, optional) — if `true`, includes timing breakdown in response headers (`X-Perf-Route-Ms`, `X-Perf-View-Incr-Ms`, `X-Perf-View-Read-Ms`, `X-Perf-Analytics-Ms`, `X-Perf-Total-Ms`)

**Response `200`:**
```json
{
  "video_id": 1,
  "views": 42,
  "total_ms": 1.24,
  "view_incr_ms": 0.41,
  "view_read_ms": 0.38,
  "analytics_ms": 0.45
}
```

**Errors:**
- `404` — video not found

---

## Error Format

All errors follow a consistent format:

```json
{
  "error": {
    "code": "not_found",
    "message": "Video not found"
  },
  "path": "/videos/999",
  "request_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
}
```

Validation errors include `details`:

```json
{
  "error": {
    "code": "validation_error",
    "message": "Request validation failed",
    "details": [
      {
        "loc": ["body", "title"],
        "msg": "Field required",
        "type": "missing"
      }
    ]
  },
  "path": "/videos/upload"
}
```

---

## Rate Limiting

Auth and mutation endpoints are rate-limited per IP. Limits are enforced in Redis.

Exceeding the limit returns `429 Too Many Requests`:
```json
{
  "error": {
    "code": "rate_limit_exceeded",
    "message": "Too many requests"
  }
}
```

---

[← Load Testing](09-load-testing.md) · [Wiki Index](index.md) · [Troubleshooting →](11-troubleshooting.md)
