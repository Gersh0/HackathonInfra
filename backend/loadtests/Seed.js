/**
 * seed.js — Fixture data seeder
 *
 * Run ONCE before any load test. Creates users, videos, and comments,
 * then writes seed_output.json with all IDs for other scripts to consume.
 *
 * Usage:
 *   k6 run seed.js
 *   k6 run seed.js -e BASE_URL=http://localhost/api
 *
 * Output:
 *   seed_output.json  →  { users: [...], videos: [...], comments: [...] }
 *
 * Rate limit note:
 *   The backend enforces 60 mutations/60s per IP. All three phases (users,
 *   videos, comments) share that budget. Sleeps are set to 1.1s per request
 *   (~54 req/min) to stay safely under the limit. Total runtime: ~3 minutes.
 *
 * Architecture note:
 *   All seeding runs in setup(). handleSummary() rebuilds the seed payload
 *   by querying the API directly (k6/http is available in handleSummary),
 *   because data.setup is unreliable across k6 runtime boundaries.
 */

import http from "k6/http";
import { check, sleep } from "k6";

// ─── Config ────────────────────────────────────────────────────────────────

const BASE_URL = __ENV.BASE_URL || "http://host.docker.internal:8000";

const SEED = {
  users: 20,
  videos: 50,
  commentsPerVideo: 2, // 50 × 2 = 100 total comments
};

// ─── k6 options ─────────────────────────────────────────────────────────────

export const options = {
  vus: 1,
  iterations: 1,
  setupTimeout: "10m", // seeding takes ~3 min at rate-limit-safe pace
  thresholds: {
    http_req_failed: ["rate<0.01"],
  },
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

function post(path, body, token = null) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers["Authorization"] = `Bearer ${token}`;
  return http.post(`${BASE_URL}${path}`, JSON.stringify(body), { headers });
}

function randomSuffix() {
  return Math.random().toString(36).slice(2, 8);
}

function fakeVideoFile() {
  return http.file(new Uint8Array([0xff, 0xfb, 0x00]).buffer, "seed_video.mp4", "video/mp4");
}

// ─── Setup — all seeding happens here ────────────────────────────────────────
// setup() return value is passed to handleSummary() as data.setup,
// which is the only reliable way to share data across k6 runtime boundaries.

export function setup() {
  const result = {
    users: [],
    videos: [],
    comments: [],
    meta: {
      base_url: BASE_URL,
      seeded_at: new Date().toISOString(),
    },
  };

  // ── 1. Create users ─────────────────────────────────────────────────────

  console.log(`[seed] Creating ${SEED.users} users...`);

  for (let i = 0; i < SEED.users; i++) {
    const displayName = `loaduser_${randomSuffix()}`;
    const res = http.post(`${BASE_URL}/users`, {
      display_name: displayName,
      provider: "local",
    });

    const ok = check(res, {
      "user created (200)": (r) => r.status === 200,
    });

    if (!ok) {
      console.error(`[seed] Failed to create user ${i}: ${res.status} ${res.body}`);
      sleep(1.1);
      continue;
    }

    const user = res.json();
    const authRes = post("/auth/token", { user_id: user.id });
    const authOk = check(authRes, {
      "token issued (200)": (r) => r.status === 200,
    });

    if (!authOk) {
      console.error(`[seed] Failed to get token for user ${user.id}: ${authRes.status} ${authRes.body}`);
      sleep(1.1);
      continue;
    }

    result.users.push({
      id: user.id,
      display_name: user.display_name,
      token: authRes.json("access_token"),
    });

    sleep(1.1);
  }

  console.log(`[seed] Created ${result.users.length} users.`);

  if (result.users.length === 0) {
    console.error("[seed] No users created — aborting.");
    return result;
  }

  // ── 2. Upload videos ─────────────────────────────────────────────────────

  console.log(`[seed] Uploading ${SEED.videos} videos...`);

  for (let i = 0; i < SEED.videos; i++) {
    const user = result.users[i % result.users.length];
    const title = `Seed Video ${i + 1} - ${randomSuffix()}`;

    const res = http.post(
      `${BASE_URL}/videos/upload`,
      {
        file: fakeVideoFile(),
        title: title,
        description: `Auto-generated seed video for load testing. Index: ${i}`,
      },
      { headers: { Authorization: `Bearer ${user.token}` } }
    );

    const ok = check(res, {
      "video uploaded (200)": (r) => r.status === 200,
    });

    if (!ok) {
      console.error(`[seed] Failed to upload video ${i}: ${res.status} ${res.body}`);
      sleep(1.1);
      continue;
    }

    result.videos.push({
      id: res.json("id"),
      title: title,
      owner_id: user.id,
    });

    sleep(1.1);
  }

  console.log(`[seed] Uploaded ${result.videos.length} videos.`);

  if (result.videos.length === 0) {
    console.error("[seed] No videos created — aborting comment seeding.");
    return result;
  }

  // ── 3. Seed comments ──────────────────────────────────────────────────

  const totalComments = result.videos.length * SEED.commentsPerVideo;
  console.log(`[seed] Seeding comments (~${totalComments} total)...`);

  for (const video of result.videos) {
    for (let c = 0; c < SEED.commentsPerVideo; c++) {
      const user = result.users[Math.floor(Math.random() * result.users.length)];
      const res = post(
        `/videos/${video.id}/comments`,
        { content: `Seed comment ${c + 1} on video ${video.id} by user ${user.id}` },
        user.token
      );

      const ok = check(res, {
        "comment created (200)": (r) => r.status === 200,
      });

      if (ok) {
        result.comments.push({ id: res.json("id"), video_id: video.id });
      }

      sleep(1.1);
    }
  }

  console.log(`[seed] Created ${result.comments.length} comments.`);
  console.log("[seed] Done. Summary:");
  console.log(`  Users:    ${result.users.length}`);
  console.log(`  Videos:   ${result.videos.length}`);
  console.log(`  Comments: ${result.comments.length}`);

  return result;
}

// ─── Default — intentional no-op ─────────────────────────────────────────────
// All work is in setup(). This function must exist for k6 to run.

export default function () {}

// ─── Write seed_output.json via handleSummary ─────────────────────────────────
// data.setup is unreliable across k6 runtime boundaries in some configurations.
// Instead, we query the API directly from handleSummary (k6/http is available
// here) to assemble the seed payload, then write it to the mounted volume path.

export function handleSummary(_data) {
  const jsonHeaders = { "Content-Type": "application/json" };

  // GET /users — paginated, limit=100 covers the 20 seeded users
  const usersRes = http.get(`${BASE_URL}/users?limit=100`);
  const rawUsers = (usersRes.status === 200 && usersRes.json("items")) || [];

  // Re-issue a token for each user — Breakpoint.js needs them for auth/upload
  const users = rawUsers.map((u) => {
    const tokenRes = http.post(
      `${BASE_URL}/auth/token`,
      JSON.stringify({ user_id: u.id }),
      { headers: jsonHeaders }
    );
    return {
      id: u.id,
      display_name: u.display_name,
      token: tokenRes.status === 200 ? tokenRes.json("access_token") : "",
    };
  });

  // GET /videos — paginated, limit=100 covers the 50 seeded videos
  const videosRes = http.get(`${BASE_URL}/videos?limit=100`);
  const rawVideos = (videosRes.status === 200 && videosRes.json("items")) || [];
  const videos = rawVideos.map((v) => ({
    id: v.id,
    title: v.title,
    owner_id: v.uploader ? v.uploader.id : null,
  }));

  const seedData = {
    users,
    videos,
    meta: {
      base_url: BASE_URL,
      seeded_at: new Date().toISOString(),
    },
  };

  return {
    // Absolute path ensures the file lands in the Docker-mounted volume
    // regardless of k6's working directory inside the container.
    "/scripts/seed_output.json": JSON.stringify(seedData, null, 2),
    stdout: `\n[seed] seed_output.json written with ${users.length} users and ${videos.length} videos.\n`,
  };
}
