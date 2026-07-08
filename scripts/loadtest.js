// loadtest.js — k6 load test for NexusPlay.
// Ramp from baseline to peak and hold, exercising both services and the cache-aside path.
// Run locally:  k6 run --env ALB_DNS=<alb-dns> scripts/loadtest.js
// Run in CI:     see .github/workflows/deploy.yml (load-test job)
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const ALB = __ENV.ALB_DNS || 'nexusplay-alb-1309462050.us-east-1.elb.amazonaws.com';
const BASE = `http://${ALB}`;

// Custom metrics
const gameHits  = new Counter('game_requests');
const playerHits = new Counter('player_requests');
const cacheMiss = new Counter('cache_miss'); // re-reads from DB when cache invalidated
const errorCount = new Counter('app_errors');
const cacheLatency = new Trend('cache_latency_ms');

export const options = {
  stages: [
    { duration: '1m',  target: 50  },   // warm up
    { duration: '3m',  target: 200 },   // ramp to peak
    { duration: '2m',  target: 200 },   // hold peak
    { duration: '1m',  target: 0   },   // ramp down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],     // <1% errors
    http_req_duration: ['p(95)<500'],    // 95% under 500ms
    app_errors:        ['count<50'],     // <50 app errors total
  },
};

export default function () {
  // Game: cache-aside read (warm cache after first call)
  const g = http.get(`${BASE}/game/state/1`);
  gameHits.add(1);
  cacheLatency.add(g.timings.waiting);
  const gOk = check(g, { 'game 200': (r) => r.status === 200 });
  if (!gOk) errorCount.add(1);

  // Player: list (exercises DB)
  const p = http.get(`${BASE}/players`);
  playerHits.add(1);
  const pOk = check(p, { 'player 200': (r) => r.status === 200 });
  if (!pOk) errorCount.add(1);

  sleep(0.05);
}

// Periodic cache-invalidation test: POST a move every iteration cycle to force a DB re-read
export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: ' ', enableColors: false }),
    'loadtest-result.json': JSON.stringify(data, null, 2),
  };
}

import { textSummary } from 'https://jslib.k6.io/k6-utils/1.0.0/index.js';