import http from 'k6/http';
import { check, sleep } from 'k6';
import {
  createHttpParams,
  createSummaryHandler,
  getTargetVus,
  recordResponse,
} from './lib/k6-common.js';

const baseUrl = __ENV.TENANT_API_BASE_URL;
const token = __ENV.TENANT_API_TOKEN;
const targetVus = getTargetVus(200);
const service = __ENV.K6_TARGET_SERVICE || 'tenant-api';
const scenario = 'tenant-ramp';
const endpoint = '/records';

export const options = {
  stages: [
    { duration: '2m', target: Math.ceil(targetVus * 0.25) },
    { duration: '3m', target: Math.ceil(targetVus * 0.75) },
    { duration: '5m', target: targetVus },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<1200'],
    http_req_failed: ['rate<0.02'],
    [`scenario_success{service:${service},scenario:${scenario}}`]: ['rate>0.98'],
  },
};

if (!baseUrl) {
  throw new Error('TENANT_API_BASE_URL is required');
}

export default function () {
  const payload = JSON.stringify({
    field: 'sample',
    timestamp: new Date().toISOString(),
  });

  const response = http.post(
    `${baseUrl}${endpoint}`,
    payload,
    createHttpParams(service, {
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
    })
  );

  recordResponse({
    response,
    service,
    scenario,
    endpoint,
  });

  check(response, {
    'create 201': (r) => r.status === 201 || r.status === 200,
  });

  sleep(0.5);
}

export const handleSummary = createSummaryHandler({
  runName: __ENV.K6_RUN_NAME || 'tenant-ramp',
  scenario,
  service,
  targetUrl: `${baseUrl}${endpoint}`,
});
