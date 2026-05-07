import http from 'k6/http';
import { check, sleep } from 'k6';
import {
  createHttpParams,
  createSummaryHandler,
  getDuration,
  getVus,
  recordResponse,
} from './lib/k6-common.js';

const baseUrl = __ENV.TENANT_API_BASE_URL;
const token = __ENV.TENANT_API_TOKEN;
const service = __ENV.K6_TARGET_SERVICE || 'tenant-api';
const scenario = 'tenant-smoke';
const endpoint = '/input/hi';

export const options = {
  vus: getVus(5),
  duration: getDuration('1m'),
  thresholds: {
    http_req_duration: ['p(95)<800', 'p(99)<1200'],
    http_req_failed: ['rate<0.01'],
    [`scenario_success{service:${service},scenario:${scenario}}`]: ['rate>0.99'],
  },
};

if (!baseUrl) {
  throw new Error('TENANT_API_BASE_URL is required');
}

export default function () {
  const response = http.get(
    `${baseUrl}${endpoint}`,
    createHttpParams(service, {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    })
  );

  recordResponse({
    response,
    service,
    scenario,
    endpoint,
  });

  check(response, {
    'status is 200': (r) => r.status === 200,
  });

  sleep(1);
}

export const handleSummary = createSummaryHandler({
  runName: __ENV.K6_RUN_NAME || 'tenant-smoke',
  scenario,
  service,
  targetUrl: `${baseUrl}${endpoint}`,
});
