/**
 * breakpoint.js — Breakpoint / ceiling finder
 *
 * Ramps VUs aggressively until the app collapses (error rate spikes or
 * latency blows past thresholds). Run this to find the performance ceiling
 * before and after each optimization pass.
 *
 * Usage:
 *   # Full weighted traffic mix (default)
 *   k6 run breakpoint.js
 *
 *   # Isolate a single scenario to find its specific ceiling
 *   k6 run breakpoint.js -e K6_SCENARIO=watch
 *   k6 run breakpoint.js -e K6_SCENARIO=browse
 *   k6 run breakpoint.js -e K6_SCENARIO=recommended
 *   k6 run breakpoint.js -e K6_SCENARIO=comments
 *   k6 run breakpoint.js -e K6_SCENARIO=auth
 *
 * Environment variables:
 *   BASE_URL      — default: http://host.docker.internal:8000
 *   K6_SCENARIO   — default: "all" (weighted mix)
 *   SEED_FILE     — default: ./seed_output.json
 *   MAX_VUS       — default: 300 (raise if your machine can handle more)
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

// ─── Config ──────────────────────────────────────────────────────────────────

const BASE_URL = __ENV.BASE_URL || "http://host.docker.internal:8000";
const SCENARIO = (__ENV.K6_SCENARIO || "all").toLowerCase();
const MAX_VUS = parseInt(__ENV.MAX_VUS || "300");
// Set THINK_TIME=0 to remove all sleep between requests (maximises RPS).
const THINK_TIME = parseFloat(__ENV.THINK_TIME !== undefined ? __ENV.THINK_TIME : "1");
// RAMP_SPEED divides all stage durations — 1 = default (~13 min), 2 = half speed (~6.5 min), 4 = quarter (~3 min).
const RAMP_SPEED = parseFloat(__ENV.RAMP_SPEED || "1");

// Load seed data — must run seed.js first
let SEED = {};
try {
  SEED = JSON.parse(open(__ENV.SEED_FILE || "./seed_output.json"));
} catch (e) {
  console.error("[breakpoint] Could not load seed_output.json. Run seed.js first.");
}

if (!SEED.users || SEED.users.length === 0 || !SEED.videos || SEED.videos.length === 0) {
  console.error("[breakpoint] seed_output.json is empty or missing users/videos. Run seed.js first.");
  // Minimal fallback — requests will 404 but the test won't hard-crash on undefined
  if (!SEED.users  || SEED.users.length  === 0) SEED.users  = [{ id: 1, token: "" }];
  if (!SEED.videos || SEED.videos.length === 0) SEED.videos = [{ id: 1 }];
  if (!SEED.comments) SEED.comments = [];
}

// ─── Custom metrics ───────────────────────────────────────────────────────────

const errorRate = new Rate("error_rate");
const recommendedLatency = new Trend("recommended_latency", true);
const watchLatency = new Trend("watch_latency", true);
const browseLatency = new Trend("browse_latency", true);

// ─── Ramp profile ─────────────────────────────────────────────────────────────
//
// Designed to find the breaking point, not sustain load.
// Each stage adds pressure — watch where errors start climbing.
//
//  0 → 20 VU  in  1m  (warm up, should be healthy)
// 20 → 60 VU  in  2m  (light load)
// 60 → 120 VU in  2m  (moderate — pool pressure starts)
// 120→ 200 VU in  2m  (heavy — expect latency climb)
// 200→ MAX VU in  2m  (ceiling probe)
// MAX VU      for 3m  (hold at peak to confirm collapse or stability)
//  →   0      in  1m  (ramp down)

function s(seconds) {
  return `${Math.max(1, Math.round(seconds / RAMP_SPEED))}s`;
}

function buildStages(maxVus) {
  return [
    { duration: s(60),  target: 20 },
    { duration: s(120), target: 60 },
    { duration: s(120), target: 120 },
    { duration: s(120), target: 200 },
    { duration: s(120), target: maxVus },
    { duration: s(180), target: maxVus },
    { duration: s(60),  target: 0 },
  ];
}

// ─── Scenario definitions ────────────────────────────────────────────────────
//
// Each scenario maps to an executor with weight-appropriate VU share.
// When K6_SCENARIO is set, only that executor runs at full MAX_VUS.

function scenarioConfig(name, vuShare, execFn) {
  const isIsolated = SCENARIO !== "all";
  const isActive = SCENARIO === "all" || SCENARIO === name;

  if (!isActive) return null;

  return {
    executor: "ramping-vus",
    stages: buildStages(isIsolated ? MAX_VUS : Math.max(5, Math.round(MAX_VUS * vuShare))),
    exec: execFn,
    gracefulRampDown: "30s",
  };
}

// VU weight distribution (must sum to 1.0):
//   browse:      35%  — hot DB read path
//   watch:       25%  — Redis view buffer
//   recommended: 20%  — Python sort CPU bomb
//   comments:    12%  — DB write + rate limit
//   auth:         8%  — JWT + upload

const rawScenarios = {
  browse:      scenarioConfig("browse",      0.35, "browseScenario"),
  watch:       scenarioConfig("watch",       0.25, "watchScenario"),
  recommended: scenarioConfig("recommended", 0.20, "recommendedScenario"),
  comments:    scenarioConfig("comments",    0.12, "commentsScenario"),
  auth:        scenarioConfig("auth",        0.08, "authScenario"),
};

// Filter out null entries (inactive scenarios in isolated mode)
const scenarios = Object.fromEntries(
  Object.entries(rawScenarios).filter(([, v]) => v !== null)
);

// ─── k6 options ───────────────────────────────────────────────────────────────

export const options = {
  scenarios,
  thresholds: {
    // These thresholds intentionally DON'T abort the test — we want to observe
    // degradation, not stop early. Set abortOnFail: false explicitly.
    http_req_failed:   [{ threshold: "rate<0.15", abortOnFail: false }],
    http_req_duration: [{ threshold: "p(95)<3000", abortOnFail: false }],
    error_rate:        [{ threshold: "rate<0.15", abortOnFail: false }],
  },
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// Each VU gets a stable user from the pool — simulates real concurrent users.
// __VU is 1-indexed and stable for the lifetime of the VU.
function myUser() {
  return SEED.users[(__VU - 1) % SEED.users.length];
}

function myVideo() {
  return randomItem(SEED.videos);
}

function authHeaders(token) {
  return { Authorization: `Bearer ${token}` };
}

function jsonHeaders() {
  return { "Content-Type": "application/json" };
}

function get(path, extraHeaders = {}) {
  return http.get(`${BASE_URL}${path}`, { headers: extraHeaders });
}

function post(path, body, token = null) {
  const headers = { ...jsonHeaders() };
  if (token) headers["Authorization"] = `Bearer ${token}`;
  return http.post(`${BASE_URL}${path}`, JSON.stringify(body), { headers });
}

function recordError(res) {
  errorRate.add(res.status >= 400);
}

// ─── Scenario functions ───────────────────────────────────────────────────────

/**
 * browse — simulates a user scrolling the home page and listing videos.
 * Hits: GET /health, GET /videos, GET /users, GET /users/{id}/feed
 * Think time: 300ms (fast browser interaction)
 */
export function browseScenario() {
  const user = myUser();

  let res = get("/health");
  check(res, { "health ok": (r) => r.status === 200 });
  recordError(res);

  res = get("/videos?page=1&limit=20");
  browseLatency.add(res.timings.duration);
  check(res, { "videos list ok": (r) => r.status === 200 });
  recordError(res);

  res = get("/users");
  check(res, { "users list ok": (r) => r.status === 200 });
  recordError(res);

  res = get(`/users/${user.id}/feed`);
  check(res, { "feed ok": (r) => r.status === 200 });
  recordError(res);

  sleep(0.3 * THINK_TIME);
}

/**
 * watch — simulates a user opening and watching a video.
 * Hits: GET /videos/{id}, GET /videos/{id}/thumbnail, GET /videos/{id}/stream
 * The stream hit is the high-bandwidth path through Nginx X-Accel-Redirect.
 * Think time: 500ms (simulates video player startup time)
 */
export function watchScenario() {
  const video = myVideo();

  let res = get(`/videos/${video.id}`);
  watchLatency.add(res.timings.duration);
  check(res, { "video detail ok": (r) => r.status === 200 });
  recordError(res);

  res = get(`/videos/${video.id}/thumbnail`);
  check(res, { "thumbnail ok": (r) => [200, 206].includes(r.status) });
  recordError(res);

  // Stream: we only request the first chunk, not the full file.
  // Range header simulates a video player fetching the first segment.
  res = http.get(`${BASE_URL}/videos/${video.id}/stream`, {
    headers: { Range: "bytes=0-65535" }, // first 64KB
  });
  check(res, { "stream ok": (r) => [200, 206].includes(r.status) });
  recordError(res);

  sleep(0.5 * THINK_TIME);
}

/**
 * recommended — simulates the sidebar recommendations panel loading.
 * This hits the known CPU-expensive path: Python in-memory sort of all videos.
 * Under high concurrency this is likely the first thing to collapse.
 * Think time: 200ms (UI sidebar, quick interaction)
 */
export function recommendedScenario() {
  const video = myVideo();

  const res = get(`/videos/${video.id}/recommended`);
  recommendedLatency.add(res.timings.duration);
  check(res, { "recommended ok": (r) => r.status === 200 });
  recordError(res);

  sleep(0.2 * THINK_TIME);
}

/**
 * comments — simulates reading and writing comments.
 * Mix: 70% reads (GET), 30% writes (POST) to respect rate limits.
 * Think time: 800ms (user reading before commenting)
 */
export function commentsScenario() {
  const video = myVideo();
  const user = myUser();

  let res = get(`/videos/${video.id}/comments?page=1&limit=20`);
  check(res, { "comments list ok": (r) => r.status === 200 });
  recordError(res);

  // Only 30% of comment VUs actually post — simulates realistic read/write ratio
  // and avoids hammering the rate limiter on every VU
  if (Math.random() < 0.3) {
    res = post(
      `/videos/${video.id}/comments`,
      { content: `Load test comment from VU ${__VU} at ${Date.now()}` },
      user.token
    );
    check(res, {
      "comment posted (200)": (r) => r.status === 200,
      "comment not rate limited": (r) => r.status !== 429,
    });
    recordError(res);
  }

  sleep(0.8 * THINK_TIME);
}

/**
 * auth — simulates login and upload flow.
 * Most expensive per-request: JWT issuance + multipart upload + delete.
 * Think time: 1s (user filling upload form)
 */
export function authScenario() {
  const user = myUser();

  // Re-auth: each VU re-authenticates to simulate session refresh
  let res = post("/auth/token", { user_id: user.id });
  check(res, { "token issued": (r) => r.status === 200 });
  recordError(res);

  const token = res.status === 200 ? res.json("access_token") : user.token;

  // Upload a minimal video file
  const uploadRes = http.post(
    `${BASE_URL}/videos/upload`,
    {
      file: http.file(
        new Uint8Array([0xff, 0xfb, 0x00]).buffer,
        `vu${__VU}_${Date.now()}.mp4`,
        "video/mp4"
      ),
      title: `VU ${__VU} upload at ${Date.now()}`,
      description: "Breakpoint test upload",
    },
    { headers: authHeaders(token) }
  );

  check(uploadRes, { "upload ok (200)": (r) => r.status === 200 });
  recordError(uploadRes);

  // Clean up immediately — don't fill disk during a long run
  if (uploadRes.status === 200) {
    const videoId = uploadRes.json("id");
    const deleteRes = http.del(
      `${BASE_URL}/videos/${videoId}`,
      null,
      { headers: authHeaders(token) }
    );
    check(deleteRes, { "delete ok (200)": (r) => r.status === 200 });
  }

  sleep(1.0 * THINK_TIME);
}

// ─── Summary ──────────────────────────────────────────────────────────────────

export function handleSummary(data) {
  const mode = SCENARIO === "all" ? "full mix" : `isolated: ${SCENARIO}`;
  const p95 = data.metrics.http_req_duration?.values?.["p(95)"] || 0;
  const errRate = data.metrics.http_req_failed?.values?.rate || 0;
  const rps = data.metrics.http_reqs?.values?.rate || 0;

  const summary = {
    mode,
    max_vus: MAX_VUS,
    peak_rps: rps.toFixed(2),
    p95_latency_ms: p95.toFixed(0),
    error_rate_pct: (errRate * 100).toFixed(2),
    recommendation: errRate > 0.1
      ? "ERROR RATE > 10% — breaking point likely reached within this run. Check Grafana for the exact VU count where errors spiked."
      : p95 > 1000
      ? "P95 > 1s but errors low — latency degradation without hard failure. Increase MAX_VUS to find collapse."
      : "App stable at this VU ceiling. Increase MAX_VUS or look at Grafana for subtle degradation signals.",
  };

  console.log("\n[breakpoint] Run summary:");
  console.log(JSON.stringify(summary, null, 2));

  return {
    "breakpoint_summary.json": JSON.stringify({ ...summary, raw: data.metrics }, null, 2),
    stdout: `\n[breakpoint] Done. Mode: ${mode}. Peak RPS: ${summary.peak_rps}. P95: ${summary.p95_latency_ms}ms. Errors: ${summary.error_rate_pct}%\n`,
  };
}
