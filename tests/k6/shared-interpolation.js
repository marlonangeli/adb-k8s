import http from 'k6/http';
import { check } from 'k6';
import {
  createHttpParams,
  createSummaryHandler,
  getDuration,
  getMaxVus,
  getPreAllocatedVus,
  getRate,
  recordResponse,
} from './lib/k6-common.js';

const interpolationUrl = __ENV.INTERPOLATION_BASE_URL;
const service = __ENV.K6_TARGET_SERVICE || 'adb-interpolation-api';
const scenario = 'shared-balance';
const endpoint = __ENV.INTERPOLATION_HEALTH_PATH || '/healthz';
const rate = getRate(8);
const duration = getDuration('2m');
const preAllocatedVUs = getPreAllocatedVus(12);
const maxVUs = getMaxVus(30);

if (!interpolationUrl) {
  throw new Error('INTERPOLATION_BASE_URL is required');
}

const thresholds = {
  http_req_duration: ['p(95)<1500', 'p(99)<2500'],
  http_req_failed: ['rate<0.01'],
};

thresholds[`scenario_success{service:${service},scenario:${scenario}}`] = ['rate>0.99'];
thresholds[`hostname_seen{service:${service},scenario:${scenario}}`] = ['rate>0.99'];
thresholds[`pod_hits{service:${service},scenario:${scenario}}`] = ['count>0'];

export const options = {
  noConnectionReuse: true,
  scenarios: {
    balance: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      maxVUs,
    },
  },
  thresholds,
};

export default function () {
  const response = http.get(`${interpolationUrl}${endpoint}`, createHttpParams(service, { closeConnection: true }));
  const { payload, pod } = recordResponse({
    response,
    service,
    scenario,
    endpoint,
  });

  check(response, {
    'status is 200': result => result.status === 200,
    'response has hostname': () => pod !== 'unknown',
    'response status is ok': () => payload?.status === 'ok',
  });
}

export const handleSummary = createSummaryHandler({
  runName: __ENV.K6_RUN_NAME || 'shared-balance',
  scenario,
  service,
  targetUrl: `${interpolationUrl}${endpoint}`,
});
