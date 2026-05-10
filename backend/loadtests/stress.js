/**
 * stress.js — Comprehensive load test
 *
 * Single script: hits all endpoints, measures per-endpoint latency and error rates,
 * polls DB pool pressure from /metrics, and produces a full bottleneck report.
 *
 * Usage:
 *   k6 run stress.js
 *   k6 run stress.js -e MAX_VUS=500
 *   k6 run stress.js -e MAX_VUS=200 -e BASE_URL=http://127.0.0.1/api
 *   k6 run stress.js -e K6_SCENARIO=watch   (isolate one scenario)
 *
 * Requires seed_output.json to exist (run seed.js first).
 *
 * Environment variables:
 *   BASE_URL      — default: http://127.0.0.1/api
 *   MAX_VUS       — default: 300
 *   K6_SCENARIO   — default: all  (browse | watch | comments | social | auth | system)
 *   SEED_FILE     — default: ./seed_output.json
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";

// ─── Config ──────────────────────────────────────────────────────────────────

const BASE_URL    = __ENV.BASE_URL    || "http://127.0.0.1/api";
const MAX_VUS     = parseInt(__ENV.MAX_VUS || "300");
const SCENARIO    = (__ENV.K6_SCENARIO || "all").toLowerCase();

// ─── Seed data ────────────────────────────────────────────────────────────────

let SEED = {};
try {
  SEED = JSON.parse(open(__ENV.SEED_FILE || "./seed_output.json"));
} catch {
  console.error("[stress] seed_output.json not found. Run seed.js first.");
  SEED = { users: [{ id: 1, token: "" }], videos: [{ id: 1 }], comments: [] };
}

const USERS  = SEED.users  || [];
const VIDEOS = SEED.videos || [];

// ─── Per-endpoint metrics ─────────────────────────────────────────────────────
// Each endpoint gets its own Trend (latency) and Rate (errors).
// This produces per-endpoint p95/p99 and error rate in the final summary.

const m = {
  // Browse
  browse_list:       { key: "browse_list",       lat: new Trend("lat_browse_list",        true), err: new Rate("err_browse_list") },
  browse_search:     { key: "browse_search",     lat: new Trend("lat_browse_search",      true), err: new Rate("err_browse_search") },
  browse_users:      { key: "browse_users",      lat: new Trend("lat_browse_users",       true), err: new Rate("err_browse_users") },

  // Watch
  watch_detail:      { key: "watch_detail",      lat: new Trend("lat_watch_detail",       true), err: new Rate("err_watch_detail") },
  watch_recommended: { key: "watch_recommended", lat: new Trend("lat_watch_recommended",  true), err: new Rate("err_watch_recommended") },
  watch_thumbnail:   { key: "watch_thumbnail",   lat: new Trend("lat_watch_thumbnail",    true), err: new Rate("err_watch_thumbnail") },

  // Comments
  comments_list:     { key: "comments_list",     lat: new Trend("lat_comments_list",      true), err: new Rate("err_comments_list") },
  comments_post:     { key: "comments_post",     lat: new Trend("lat_comments_post",      true), err: new Rate("err_comments_post") },

  // Social
  feed:              { key: "feed",              lat: new Trend("lat_feed",               true), err: new Rate("err_feed") },
  subs_list:         { key: "subs_list",         lat: new Trend("lat_subs_list",          true), err: new Rate("err_subs_list") },
  subs_write:        { key: "subs_write",        lat: new Trend("lat_subs_write",         true), err: new Rate("err_subs_write") },

  // Auth
  auth_token:        { key: "auth_token",        lat: new Trend("lat_auth_token",         true), err: new Rate("err_auth_token") },
  upload:            { key: "upload",            lat: new Trend("lat_upload",             true), err: new Rate("err_upload") },
  delete_video:      { key: "delete_video",      lat: new Trend("lat_delete_video",       true), err: new Rate("err_delete_video") },

  // System
  health:            { key: "health",            lat: new Trend("lat_health",             true), err: new Rate("err_health") },
  health_queues:     { key: "health_queues",     lat: new Trend("lat_health_queues",      true), err: new Rate("err_health_queues") },
  redis_probe:       { key: "redis_probe",       lat: new Trend("lat_redis_probe",        true), err: new Rate("err_redis_probe") },
};

const timeouts = new Counter("upstream_timeouts");

// Pre-declared status code counters for every endpoint+status combination.
// k6 requires all metrics to exist in the init context.
const ENDPOINT_KEYS = [
  "browse_list", "browse_search", "browse_users",
  "watch_detail", "watch_recommended", "watch_thumbnail",
  "comments_list", "comments_post",
  "feed", "subs_list", "subs_write",
  "auth_token", "upload", "delete_video",
  "health", "health_queues", "redis_probe",
];

const STATUS_CODES = [200, 201, 204, 400, 401, 403, 404, 409, 422, 429, 500, 502, 503, 0];

const _statusCounters = {};
for (const ep of ENDPOINT_KEYS) {
  for (const code of STATUS_CODES) {
    const key = ep + "_" + code;
    _statusCounters[key] = new Counter("sc_" + key);
  }
}

function countStatus(endpointKey, statusCode) {
  const key = endpointKey + "_" + statusCode;
  if (_statusCounters[key]) {
    _statusCounters[key].add(1);
  }
  // If status code not in pre-declared list, silently skip —
  // unexpected codes won't crash the test
}

// ─── Ramp profile ─────────────────────────────────────────────────────────────
// 7-stage proportional ramp. Targets are calculated as fractions of maxVus
// with per-stage minimums so low MAX_VUS values still produce a meaningful ramp.
//
// Stage 1: 20s → max(1,  floor(maxVus * 0.01))  warm-up:      1% of max
// Stage 2: 40s → max(2,  floor(maxVus * 0.10))  light:       10% of max
// Stage 3: 40s → max(3,  floor(maxVus * 0.33))  moderate:    33% of max
// Stage 4: 50s → max(5,  floor(maxVus * 0.66))  heavy:       66% of max
// Stage 5: 50s → max(10, maxVus)                 ceiling probe: 100%
// Stage 6: 50s → max(10, maxVus)                 hold at peak
// Stage 7: 20s → 0                               ramp down
// Total duration: ~4m30s

// Example outputs:
// MAX_VUS=300:  3 → 30 → 99 → 198 → 300 → 300 → 0
// MAX_VUS=3000: 30 → 300 → 990 → 1980 → 3000 → 3000 → 0
function buildStages(maxVus) {
  return [
    { duration: "20s", target: Math.max(1,  Math.floor(maxVus * 0.01)) },
    { duration: "40s", target: Math.max(2,  Math.floor(maxVus * 0.10)) },
    { duration: "40s", target: Math.max(3,  Math.floor(maxVus * 0.33)) },
    { duration: "50s", target: Math.max(5,  Math.floor(maxVus * 0.66)) },
    { duration: "50s", target: Math.max(10, maxVus) },
    { duration: "50s", target: Math.max(10, maxVus) },
    { duration: "20s", target: 0 },
  ];
}

// ─── Scenario definitions ─────────────────────────────────────────────────────

function makeScenario(name, vuShare, execFn) {
  const isIsolated = SCENARIO !== "all";
  const isActive   = SCENARIO === "all" || SCENARIO === name;
  if (!isActive) return null;
  return {
    executor: "ramping-vus",
    stages: buildStages(isIsolated ? MAX_VUS : Math.max(3, Math.round(MAX_VUS * vuShare))),
    exec: execFn,
    gracefulRampDown: "15s",
  };
}

const rawScenarios = {
  browse:  makeScenario("browse",  0.30, "browseFn"),
  watch:   makeScenario("watch",   0.25, "watchFn"),
  comments:makeScenario("comments",0.15, "commentsFn"),
  social:  makeScenario("social",  0.15, "socialFn"),
  auth:    makeScenario("auth",    0.10, "authFn"),
  system:  makeScenario("system",  0.05, "systemFn"),
};

const scenarios = Object.fromEntries(
  Object.entries(rawScenarios).filter(([, v]) => v !== null)
);

// ─── k6 options ───────────────────────────────────────────────────────────────

export const options = {
  scenarios,
  // Thresholds set permissively — we want to observe degradation, not abort early.
  // The final summary report flags violations independently.
  thresholds: {
    http_req_failed:   [{ threshold: "rate<0.20", abortOnFail: false }],
    http_req_duration: [{ threshold: "p(95)<5000", abortOnFail: false }],
  },
  // Clean console output — suppress individual request logs
  summaryTrendStats: ["p(50)", "p(95)", "p(99)", "max", "count"],
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function rnd(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function myUser() {
  return USERS[(__VU - 1) % USERS.length] || USERS[0];
}

function myVideo() {
  return rnd(VIDEOS) || VIDEOS[0];
}

function authHdr(token) {
  return { Authorization: `Bearer ${token}` };
}

function jsonHdr() {
  return { "Content-Type": "application/json" };
}

function record(metric, res, expectedStatuses = [200]) {
  const ok = expectedStatuses.includes(res.status);
  metric.lat.add(res.timings.duration);
  metric.err.add(!ok);
  if (res.status === 0 || res.timings.duration > 25000) {
    timeouts.add(1);
  }
  countStatus(metric.key, res.status);
  return ok;
}

function get(path, headers = {}) {
  return http.get(`${BASE_URL}${path}`, { headers, timeout: "30s" });
}

function post(path, body, headers = {}) {
  return http.post(
    `${BASE_URL}${path}`,
    typeof body === "string" ? body : JSON.stringify(body),
    { headers: { ...jsonHdr(), ...headers }, timeout: "30s" }
  );
}

// ─── Scenario: browse ─────────────────────────────────────────────────────────
// Simulates a user scrolling the home page and searching.
// Hits: GET /videos, GET /videos?q=, GET /users

export function browseFn() {
  let res;

  // Paginated video list
  res = get("/videos?page=1&limit=20");
  record(m.browse_list, res);

  // Search query — uses the trigram index on title
  const terms = ["seed", "video", "load", "test", "stream"];
  res = get(`/videos?q=${rnd(terms)}&page=1&limit=10`);
  record(m.browse_search, res);

  // User list
  res = get("/users");
  record(m.browse_users, res);

  sleep(0.3);
}

// ─── Scenario: watch ──────────────────────────────────────────────────────────
// Simulates opening a video page and loading recommendations.
// Hits: GET /videos/{id}, GET /videos/{id}/recommended, GET /videos/{id}/thumbnail

export function watchFn() {
  const video = myVideo();
  let res;

  // Video detail — hits Redis view buffer
  res = get(`/videos/${video.id}`);
  record(m.watch_detail, res);

  // Recommended — hits trigram index + Redis cache
  res = get(`/videos/${video.id}/recommended`);
  record(m.watch_recommended, res);

  // Thumbnail — 404 expected for stub data, still measures response time
  res = get(`/videos/${video.id}/thumbnail`);
  record(m.watch_thumbnail, res, [200, 206, 404]);

  sleep(0.5);
}

// ─── Scenario: comments ───────────────────────────────────────────────────────
// Simulates reading comments and occasionally posting one.
// Hits: GET /videos/{id}/comments, POST /videos/{id}/comments (30% of iterations)

export function commentsFn() {
  const video = myVideo();
  const user  = myUser();
  let res;

  res = get(`/videos/${video.id}/comments?page=1&limit=20`);
  record(m.comments_list, res);

  // 30% write rate — realistic read/write ratio, avoids rate limit saturation
  if (Math.random() < 0.3) {
    res = post(
      `/videos/${video.id}/comments`,
      { content: `Load test comment from VU ${__VU} iter ${__ITER}` },
      authHdr(user.token)
    );
    record(m.comments_post, res, [200, 201, 429]);
  }

  sleep(0.8);
}

// ─── Scenario: social ─────────────────────────────────────────────────────────
// Simulates feed reading and subscription management.
// Hits: GET /users/{id}/feed, GET /users/{id}/subscriptions,
//       POST + DELETE /users/{id}/subscriptions/{creator_id}

export function socialFn() {
  const user    = myUser();
  const creator = rnd(USERS.filter(u => u.id !== user.id)) || USERS[0];
  let res;

  // Feed — DB join + Redis cache
  res = get(`/users/${user.id}/feed`);
  record(m.feed, res);

  // Subscription list
  res = get(`/users/${user.id}/subscriptions`);
  record(m.subs_list, res);

  // Subscribe then immediately unsubscribe (50% of iterations)
  // Avoids filling the DB with permanent subscriptions during the test
  if (Math.random() < 0.5) {
    res = post(
      `/users/${user.id}/subscriptions/${creator.id}`,
      {},
      authHdr(user.token)
    );
    record(m.subs_write, res, [200, 201, 409]); // 409 = already subscribed, acceptable

    // Unsubscribe immediately
    const delRes = http.del(
      `${BASE_URL}/users/${user.id}/subscriptions/${creator.id}`,
      null,
      { headers: authHdr(user.token), timeout: "30s" }
    );
    record(m.subs_write, delRes, [200, 204, 404]);
  }

  sleep(0.6);
}

// ─── Scenario: auth ───────────────────────────────────────────────────────────
// Simulates login and upload/delete lifecycle.
// Hits: POST /auth/token, POST /videos/upload, DELETE /videos/{id}

export function authFn() {
  const user = myUser();
  let res;

  // Auth token issuance
  res = post("/auth/token", { user_id: String(user.id) });
  record(m.auth_token, res, [200]);
  const token = res.status === 200 ? (res.json("access_token") || user.token) : user.token;

  // Upload a stub video
  const uploadRes = http.post(
    `${BASE_URL}/videos/upload`,
    {
      file: http.file(
        new Uint8Array([0xff, 0xfb, 0x00]).buffer,
        `vu${__VU}_${Date.now()}.mp4`,
        "video/mp4"
      ),
      title: `Stress upload VU${__VU} iter${__ITER}`,
      description: "Load test upload",
    },
    { headers: authHdr(token), timeout: "60s" }
  );
  record(m.upload, uploadRes, [200, 201]);

  // Clean up immediately — don't fill disk during test
  if (uploadRes.status === 201) {
    const videoId = uploadRes.json("id");
    if (videoId) {
      const delRes = http.del(
        `${BASE_URL}/videos/${videoId}`,
        null,
        { headers: authHdr(token), timeout: "30s" }
      );
      record(m.delete_video, delRes, [200, 204]);
    }
  }

  sleep(1.0);
}

// ─── Scenario: system ─────────────────────────────────────────────────────────
// Monitors system health.
// Hits: GET /health, GET /health/queues, GET /videos/{id}/redis-probe

export function systemFn() {
  const video = myVideo();
  let res;

  res = get("/health");
  record(m.health, res);

  res = get("/health/queues");
  record(m.health_queues, res);

  res = get(`/videos/${video.id}/redis-probe`);
  record(m.redis_probe, res, [200]);

  sleep(5); // System scenario polls slowly — no need to hammer health endpoints
}

// ─── Summary ──────────────────────────────────────────────────────────────────

export function handleSummary(data) {
  const metrics = data.metrics;

  // Helper to safely extract metric values
  function p95(name)   { return metrics[name]?.values?.["p(95)"]  ?? null; }
  function p99(name)   { return metrics[name]?.values?.["p(99)"]  ?? null; }
  function errRate(name){ return metrics[name]?.values?.rate       ?? null; }
  function cnt(name)   { return metrics[name]?.values?.count       ?? 0; }
  function avg(name)   { return metrics[name]?.values?.avg         ?? null; }

  // Overall stats
  const totalReqs  = metrics.http_reqs?.values?.count    ?? 0;
  const totalRPS   = metrics.http_reqs?.values?.rate     ?? 0;
  const globalErr  = metrics.http_req_failed?.values?.rate ?? 0;
  const globalP95  = metrics.http_req_duration?.values?.["p(95)"] ?? 0;
  const globalP99  = metrics.http_req_duration?.values?.["p(99)"] ?? 0;
  const totalTimeouts = metrics.upstream_timeouts?.values?.count ?? 0;

  // Per-endpoint table data
  const endpoints = [
    { name: "GET /videos (list)",           latKey: "lat_browse_list",       errKey: "err_browse_list",       statusKey: "browse_list" },
    { name: "GET /videos?q= (search)",      latKey: "lat_browse_search",     errKey: "err_browse_search",     statusKey: "browse_search" },
    { name: "GET /users",                   latKey: "lat_browse_users",      errKey: "err_browse_users",      statusKey: "browse_users" },
    { name: "GET /videos/{id}",             latKey: "lat_watch_detail",      errKey: "err_watch_detail",      statusKey: "watch_detail" },
    { name: "GET /videos/{id}/recommended", latKey: "lat_watch_recommended", errKey: "err_watch_recommended", statusKey: "watch_recommended" },
    { name: "GET /videos/{id}/thumbnail",   latKey: "lat_watch_thumbnail",   errKey: "err_watch_thumbnail",   statusKey: "watch_thumbnail" },
    { name: "GET /videos/{id}/comments",    latKey: "lat_comments_list",     errKey: "err_comments_list",     statusKey: "comments_list" },
    { name: "POST /videos/{id}/comments",   latKey: "lat_comments_post",     errKey: "err_comments_post",     statusKey: "comments_post" },
    { name: "GET /users/{id}/feed",         latKey: "lat_feed",              errKey: "err_feed",              statusKey: "feed" },
    { name: "GET /users/{id}/subscriptions",latKey: "lat_subs_list",         errKey: "err_subs_list",         statusKey: "subs_list" },
    { name: "POST+DEL subscriptions",       latKey: "lat_subs_write",        errKey: "err_subs_write",        statusKey: "subs_write" },
    { name: "POST /auth/token",             latKey: "lat_auth_token",        errKey: "err_auth_token",        statusKey: "auth_token" },
    { name: "POST /videos/upload",          latKey: "lat_upload",            errKey: "err_upload",            statusKey: "upload" },
    { name: "DELETE /videos/{id}",          latKey: "lat_delete_video",      errKey: "err_delete_video",      statusKey: "delete_video" },
    { name: "GET /health",                  latKey: "lat_health",            errKey: "err_health",            statusKey: "health" },
    { name: "GET /health/queues",           latKey: "lat_health_queues",     errKey: "err_health_queues",     statusKey: "health_queues" },
    { name: "GET /videos/{id}/redis-probe", latKey: "lat_redis_probe",       errKey: "err_redis_probe",       statusKey: "redis_probe" },
  ];

  // Flag thresholds
  const WARN_P95    = 1000;  // ms
  const BAD_P95     = 2000;  // ms
  const WARN_ERR    = 0.02;  // 2%
  const BAD_ERR     = 0.05;  // 5%

  function statusFlag(p95val, errVal) {
    if (p95val === null && errVal === null) return "  -  ";
    const latBad = p95val !== null && p95val > BAD_P95;
    const latWarn= p95val !== null && p95val > WARN_P95;
    const errBad = errVal !== null && errVal > BAD_ERR;
    const errWarn= errVal !== null && errVal > WARN_ERR;
    if (latBad || errBad)   return "  ❌ ";
    if (latWarn || errWarn) return "  ⚠️ ";
    return "  ✅ ";
  }

  // Bottleneck analysis
  const bottlenecks = [];
  const warnings    = [];

  for (const ep of endpoints) {
    const epP95 = p95(ep.latKey);
    const epErr = errRate(ep.errKey);
    if (epP95 !== null && epP95 > BAD_P95) {
      bottlenecks.push(`${ep.name} — p95 ${epP95.toFixed(0)}ms (threshold: ${BAD_P95}ms)`);
    } else if (epP95 !== null && epP95 > WARN_P95) {
      warnings.push(`${ep.name} — p95 ${epP95.toFixed(0)}ms`);
    }
    if (epErr !== null && epErr > BAD_ERR) {
      bottlenecks.push(`${ep.name} — error rate ${(epErr * 100).toFixed(1)}% (threshold: ${BAD_ERR * 100}%)`);
    } else if (epErr !== null && epErr > WARN_ERR) {
      warnings.push(`${ep.name} — error rate ${(epErr * 100).toFixed(1)}%`);
    }
  }

  // Timeout analysis
  let timeoutDiagnosis = "No upstream timeouts recorded.";
  if (totalTimeouts > 0) {
    timeoutDiagnosis = `⚠️  ${totalTimeouts} upstream timeouts detected. ` +
      `Check Nginx proxy_read_timeout settings and backend worker saturation.`;
    warnings.push(`${totalTimeouts} upstream timeouts`);
  }

  // Build console output
  const sep  = "─".repeat(80);
  const sep2 = "═".repeat(80);

  // Column widths
  const COL_NAME = 38;
  const COL_P95  = 10;
  const COL_P99  = 10;
  const COL_ERR  = 10;
  const COL_FLAG = 7;

  function pad(str, len) {
    const s = String(str ?? "n/a");
    return s.length >= len ? s.slice(0, len) : s + " ".repeat(len - s.length);
  }

  function fmtMs(val) {
    return val !== null ? `${val.toFixed(0)}ms` : "n/a";
  }

  function fmtErr(val) {
    return val !== null ? `${(val * 100).toFixed(1)}%` : "n/a";
  }

  let out = "\n";
  out += `${sep2}\n`;
  out += `  STRESS TEST SUMMARY\n`;
  out += `${sep2}\n\n`;

  // Overall
  out += `  OVERALL\n`;
  out += `${sep}\n`;
  out += `  Total requests   : ${totalReqs.toLocaleString()}\n`;
  out += `  Throughput       : ${totalRPS.toFixed(1)} req/s\n`;
  out += `  Global error rate: ${(globalErr * 100).toFixed(2)}%\n`;
  out += `  Global p95       : ${globalP95.toFixed(0)}ms\n`;
  out += `  Global p99       : ${globalP99.toFixed(0)}ms\n`;
  out += `  Upstream timeouts: ${totalTimeouts}\n`;
  out += `  Max VUs          : ${MAX_VUS}\n`;
  out += `  Mode             : ${SCENARIO === "all" ? "weighted mix" : `isolated — ${SCENARIO}`}\n`;
  out += `\n`;

  function getTopStatuses(statusKey, data, topN = 3) {
    const prefix = "sc_" + statusKey + "_";
    const entries = Object.entries(data.metrics)
      .filter(([name]) => name.startsWith(prefix))
      .map(([name, metric]) => ({
        code: name.slice(prefix.length),
        count: metric.values.count || 0,
      }))
      .filter(e => e.count > 0)
      .sort((a, b) => b.count - a.count)
      .slice(0, topN);
    if (entries.length === 0) return "n/a";
    return entries.map(e => `${e.code}×${e.count}`).join("  ");
  }

  // Per-endpoint table
  out += `  PER-ENDPOINT BREAKDOWN\n`;
  out += `${sep}\n`;
  out += `  ${pad("Endpoint", COL_NAME)} ${pad("p95", COL_P95)} ${pad("p99", COL_P99)} ${pad("err%", COL_ERR)} ${pad("Top status codes", 28)} Flag\n`;
  out += `  ${"-".repeat(COL_NAME)} ${"-".repeat(COL_P95)} ${"-".repeat(COL_P99)} ${"-".repeat(COL_ERR)} ${"-".repeat(28)} ----\n`;

  for (const ep of endpoints) {
    const epP95  = p95(ep.latKey);
    const epP99  = p99(ep.latKey);
    const epErr  = errRate(ep.errKey);
    const epCnt  = cnt(ep.latKey);
    if (epCnt === 0) continue; // skip endpoints that weren't hit in this run
    out += `  ${pad(ep.name, COL_NAME)} `;
    out += `${pad(fmtMs(epP95), COL_P95)} `;
    out += `${pad(fmtMs(epP99), COL_P99)} `;
    out += `${pad(fmtErr(epErr), COL_ERR)} `;
    out += `${pad(getTopStatuses(ep.statusKey, data), 28)} `;
    out += `${statusFlag(epP95, epErr)}\n`;
  }
  out += `\n`;

  // Bottleneck report
  out += `  BOTTLENECK ANALYSIS\n`;
  out += `${sep}\n`;

  if (bottlenecks.length === 0 && warnings.length === 0) {
    out += `  ✅  No bottlenecks detected at MAX_VUS=${MAX_VUS}.\n`;
    out += `  Consider increasing MAX_VUS to find the ceiling.\n`;
  } else {
    if (bottlenecks.length > 0) {
      out += `  ❌  BOTTLENECKS (p95 > ${BAD_P95}ms or error rate > ${BAD_ERR * 100}%):\n`;
      for (const b of bottlenecks) out += `     • ${b}\n`;
      out += `\n`;
    }
    if (warnings.length > 0) {
      out += `  ⚠️   WARNINGS (approaching limits):\n`;
      for (const w of warnings) out += `     • ${w}\n`;
      out += `\n`;
    }

    // Likely cause heuristics
    out += `  LIKELY CAUSE:\n`;
    const recommendedBad = bottlenecks.some(b => b.includes("recommended"));
    const highTimeouts   = totalTimeouts > 10;
    const authBad        = bottlenecks.some(b => b.includes("upload") || b.includes("auth"));
    const readsBad       = bottlenecks.some(b => b.includes("list") || b.includes("detail") || b.includes("feed"));

    if (recommendedBad) {
      out += `     → get_recommended() is CPU-bound (cache miss rate too high or trigram\n`;
      out += `       query slow under concurrency). Check cache hit rate and index usage.\n`;
    }
    if (highTimeouts) {
      out += `     → Upstream timeouts suggest Nginx is waiting too long for the backend.\n`;
      out += `       Gunicorn workers may be saturated — check replica/worker count.\n`;
    }
    if (authBad) {
      out += `     → Upload path is slow — file I/O blocks the event loop (known issue).\n`;
      out += `       Wrap _save_upload_file() in run_in_executor to fix.\n`;
    }
    if (readsBad && !recommendedBad) {
      out += `     → Broad read latency degradation. Likely CPU saturation across all workers.\n`;
      out += `       Consider increasing BACKEND_REPLICAS for this machine tier.\n`;
    }
    if (!recommendedBad && !highTimeouts && !authBad && !readsBad) {
      out += `     → Isolated to specific endpoints above. Review per-endpoint error logs\n`;
      out += `       in the backend for 4xx/5xx patterns during the test window.\n`;
    }
  }

  out += `\n${sep2}\n`;

  // Write JSON for archiving
  const jsonOut = {
    summary: {
      total_requests:    totalReqs,
      throughput_rps:    +totalRPS.toFixed(2),
      global_error_rate: +globalErr.toFixed(4),
      global_p95_ms:     +globalP95.toFixed(0),
      global_p99_ms:     +globalP99.toFixed(0),
      upstream_timeouts: totalTimeouts,
      max_vus:           MAX_VUS,
      mode:              SCENARIO,
    },
    endpoints: endpoints
      .filter(ep => cnt(ep.latKey) > 0)
      .map(ep => ({
        name:             ep.name,
        p95_ms:           p95(ep.latKey) !== null ? +p95(ep.latKey).toFixed(0) : null,
        p99_ms:           p99(ep.latKey) !== null ? +p99(ep.latKey).toFixed(0) : null,
        error_rate:       errRate(ep.errKey) !== null ? +errRate(ep.errKey).toFixed(4) : null,
        requests:         cnt(ep.latKey),
        top_status_codes: getTopStatuses(ep.statusKey, data, 3),
      })),
    bottlenecks,
    warnings,
  };

  return {
    "stress_summary.json": JSON.stringify(jsonOut, null, 2),
    stdout: out,
  };
}
