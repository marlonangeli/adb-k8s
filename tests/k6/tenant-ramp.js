import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.TENANT_API_BASE_URL;
const token = __ENV.TENANT_API_TOKEN;
const stagesEnv = __ENV.TARGET_VUS ? Number(__ENV.TARGET_VUS) : 200;

export const options = {
  stages: [
    { duration: '2m', target: Math.ceil(stagesEnv * 0.25) },
    { duration: '3m', target: Math.ceil(stagesEnv * 0.75) },
    { duration: '5m', target: stagesEnv },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<1200'],
    http_req_failed: ['rate<0.02'],
  },
};

if (!baseUrl) {
  throw new Error('TENANT_API_BASE_URL is required');
}

export default function () {
  const headers = token ? { Authorization: `Bearer ${token}` } : {};
  const payload = JSON.stringify({
    field: 'sample',
    timestamp: new Date().toISOString(),
  });
  const res = http.post(`${baseUrl}/records`, payload, {
    headers: { 'Content-Type': 'application/json', ...headers },
  });
  check(res, {
    'create 201': (r) => r.status === 201 || r.status === 200,
  });
  sleep(0.5);
}
