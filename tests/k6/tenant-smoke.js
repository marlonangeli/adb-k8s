import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 5,
  duration: '1m',
  thresholds: {
    http_req_duration: ['p(95)<800', 'p(99)<1200'],
    http_req_failed: ['rate<0.01'],
  },
};

const baseUrl = __ENV.TENANT_API_BASE_URL;
const token = __ENV.TENANT_API_TOKEN;

if (!baseUrl) {
  throw new Error('TENANT_API_BASE_URL is required');
}

export default function () {
  const headers = token ? { Authorization: `Bearer ${token}` } : {};
  const res = http.get(`${baseUrl}/records`, { headers });
  check(res, {
    'status is 200': (r) => r.status === 200,
  });

  sleep(1);
}
