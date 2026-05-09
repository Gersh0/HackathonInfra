import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Counter } from 'k6/metrics';

// ===============================
// CONFIG
// ===============================

const RAW_BASE_URL = __ENV.BASE_URL || 'http://nginx';
const BASE_URL = RAW_BASE_URL.replace(/\/+$/, '');

const VIDEO_ID = Number(__ENV.VIDEO_ID || 1);

const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '60s';

const RESPONSE_TIME_LIMIT_MS = Number(
  __ENV.RESPONSE_TIME_LIMIT_MS || 3000
);

const DEBUG = __ENV.DEBUG === '1';

// ===============================
// CUSTOM METRICS
// ===============================

const errorRate = new Rate('errors');

const jsonParseErrors = new Counter('json_parse_errors');
const non200Responses = new Counter('non_200_responses');
const slowResponses = new Counter('slow_responses');

// ===============================
// TEST OPTIONS
// ===============================

export const options = {
  scenarios: {
    extreme_stress: {
      executor: 'ramping-vus',

      stages: [
        { duration: '60s', target: 500 },
        { duration: '60s', target: 1000 },
        { duration: '60s', target: 2000 },
        { duration: '60s', target: 3000 },
        { duration: '60s', target: 5000 },

        // Mantener carga máxima
        { duration: '180s', target: 5000 },

        // Ramp down
        { duration: '60s', target: 2000 },
        { duration: '30s', target: 0 },
      ],

      gracefulRampDown: '30s',
      exec: 'watch_video',
    },
  },

  thresholds: {
    // Menos del 10% de fallos
    http_req_failed: ['rate<0.10'],

    // Latencia objetivo
    http_req_duration: [
      'p(95)<3000',
      'p(99)<5000',
    ],

    // Checks exitosos
    checks: ['rate>0.90'],

    // Error rate personalizada
    errors: ['rate<0.10'],

    // Contadores auxiliares
    json_parse_errors: ['count<1000000'],
    non_200_responses: ['count<1000000'],
    slow_responses: ['count<1000000'],
  },
};

// ===============================
// MAIN TEST
// ===============================

export function watch_video() {
  const url = `${BASE_URL}/api/videos/${VIDEO_ID}`;

  const res = http.get(url, {
    timeout: REQUEST_TIMEOUT,

    tags: {
      endpoint: 'video_detail',
      video_id: String(VIDEO_ID),
    },
  });

  // -------------------------------
  // Métricas auxiliares
  // -------------------------------

  if (res.status !== 200) {
    non200Responses.add(1);
  }

  if (res.timings.duration > RESPONSE_TIME_LIMIT_MS) {
    slowResponses.add(1);
  }

  // -------------------------------
  // Parseo seguro de JSON
  // -------------------------------

  let body = null;
  let parsedOk = true;

  try {
    body = res.json();
  } catch (e) {
    parsedOk = false;
    jsonParseErrors.add(1);
  }

  const hasValidJson =
    parsedOk &&
    body &&
    typeof body === 'object' &&
    typeof body.title === 'string' &&
    typeof body.views === 'number' &&
    typeof body.id === 'number';

  // -------------------------------
  // Checks
  // -------------------------------

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,

    'response has valid JSON': () => hasValidJson,

    'has title': () =>
      hasValidJson && body.title.length > 0,

    'has numeric views': () =>
      hasValidJson && Number.isFinite(body.views),

    'has numeric id': () =>
      hasValidJson && Number.isFinite(body.id),

    'response time acceptable': (r) =>
      r.timings.duration <= RESPONSE_TIME_LIMIT_MS,
  });

  // -------------------------------
  // Manejo de errores SIN SPAM
  // -------------------------------

  if (!ok) {
    errorRate.add(1);

    // Solo imprimir errores si DEBUG=1
    if (DEBUG) {
      console.error(
        `FAIL status=${res.status} ` +
        `duration=${res.timings.duration.toFixed(1)}ms ` +
        `url=${url}`
      );
    }
  } else {
    errorRate.add(0);
  }

  // Simulación de usuario real
  sleep(0.2);
}

// ===============================
// TEARDOWN
// ===============================

export function teardown() {
  const finalUrl = `${BASE_URL}/api/videos/${VIDEO_ID}`;

  const finalResponse = http.get(finalUrl, {
    timeout: REQUEST_TIMEOUT,

    tags: {
      endpoint: 'video_detail_final',
      video_id: String(VIDEO_ID),
    },
  });

  if (finalResponse.status === 200) {
    try {
      const data = finalResponse.json();

      console.log(
        `Final view count for video ${VIDEO_ID}: ${data.views}`
      );
    } catch (e) {
      console.log(
        `Final request succeeded but JSON parsing failed`
      );
    }
  } else {
    console.log(
      `Final request failed with status ${finalResponse.status}`
    );
  }

  console.log('5K stress test completed');
}

// ===============================
// CLEAN SUMMARY
// ===============================

export function handleSummary(data) {
  const failedRate =
    data.metrics.http_req_failed?.rate || 0;

  const p95 =
    data.metrics.http_req_duration?.values?.['p(95)'] || 0;

  const p99 =
    data.metrics.http_req_duration?.values?.['p(99)'] || 0;

  const totalReqs =
    data.metrics.http_reqs?.count || 0;

  return {
    stdout: `
========================================
          STRESS TEST SUMMARY
========================================

Total Requests:        ${totalReqs}
Failed Request Rate:   ${(failedRate * 100).toFixed(2)}%

Latency:
  p95:                 ${p95.toFixed(2)} ms
  p99:                 ${p99.toFixed(2)} ms

========================================
`,
    'summary.json': JSON.stringify(data, null, 2),
  };
}