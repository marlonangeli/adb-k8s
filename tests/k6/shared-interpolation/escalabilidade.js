import http from 'k6/http';
import { check, sleep } from 'k6';
import {
  createEndpointTags,
  createHttpParams,
  createSummaryHandler,
  getTargetVus,
  recordResponse,
} from '../lib/k6-common.js';

const interpolationUrl = __ENV.INTERPOLATION_BASE_URL;
const service = __ENV.K6_TARGET_SERVICE || 'adb-interpolation-api';
const scenario = 'shared-escalabilidade';
const loadEndpoint = __ENV.INTERPOLATION_SCALABILITY_ENDPOINT || '/kriging';
const healthEndpoint = __ENV.INTERPOLATION_HEALTH_PATH || '/healthz';
const payloadPath = __ENV.INTERPOLATION_SCALABILITY_PAYLOAD || './payloads/kriging.json';

const toNumber = (value, fallback) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const stageDuration = (key, fallback) => __ENV[key] || fallback;
const targetVus = getTargetVus(30);
const firstRampTarget = Math.max(1, Math.ceil(targetVus * 0.25));
const secondRampTarget = Math.max(firstRampTarget, Math.ceil(targetVus * 0.75));
const expectedStatus = toNumber(__ENV.INTERPOLATION_SCALABILITY_EXPECTED_STATUS, 201);
const sleepSeconds = toNumber(__ENV.K6_SLEEP_SECONDS, 0.5);

export const options = {
  discardResponseBodies: true,
  systemTags: ['status', 'method', 'name', 'group', 'check', 'scenario', 'expected_response'],
  scenarios: {
    escalabilidade: {
      executor: 'ramping-vus',
      gracefulRampDown: stageDuration('K6_GRACEFUL_RAMP_DOWN', '30s'),
      stages: [
        { duration: stageDuration('K6_RAMP_STAGE_1_DURATION', '2m'), target: firstRampTarget },
        { duration: stageDuration('K6_RAMP_STAGE_2_DURATION', '3m'), target: secondRampTarget },
        { duration: stageDuration('K6_HOLD_DURATION', '5m'), target: targetVus },
        { duration: stageDuration('K6_RAMP_DOWN_DURATION', '2m'), target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<5000', 'p(99)<10000'],
    http_req_failed: ['rate<0.05'],
    checks: ['rate>0.95'],
    [`scenario_success{service:${service},scenario:${scenario}}`]: ['rate>0.95'],
    [`pod_hits{service:${service},scenario:${scenario}}`]: ['count>0'],
  },
};

if (!interpolationUrl) {
  throw new Error('INTERPOLATION_BASE_URL is required');
}

const payload = open(payloadPath);

const requestParams = (method, endpoint, extra = {}) => createHttpParams(service, {
  ...extra,
  tags: createEndpointTags(method, endpoint, {
    endpoint_group: 'shared-escalabilidade',
    ...(extra.tags || {}),
  }),
});

export default function () {
  const loadResponse = http.post(
    `${interpolationUrl}${loadEndpoint}`,
    payload,
    requestParams('POST', loadEndpoint, {
      headers: { 'Content-Type': 'application/json' },
    })
  );

  recordResponse({
    response: loadResponse,
    service,
    scenario,
    endpoint: loadEndpoint,
  });

  check(loadResponse, {
    [`${loadEndpoint} status is ${expectedStatus}`]: response => response.status === expectedStatus,
  });

  const healthResponse = http.get(`${interpolationUrl}${healthEndpoint}`, requestParams('GET', healthEndpoint, {
    closeConnection: true,
    responseType: 'text',
  }));
  const { pod } = recordResponse({
    response: healthResponse,
    service,
    scenario,
    endpoint: healthEndpoint,
  });

  check(healthResponse, {
    [`${healthEndpoint} status is 200`]: response => response.status === 200,
    'health response has hostname': () => pod !== 'unknown',
  });

  sleep(sleepSeconds);
}

export const handleSummary = createSummaryHandler({
  runName: __ENV.K6_RUN_NAME || 'shared-escalabilidade',
  scenario,
  service,
  targetUrl: `${interpolationUrl}${loadEndpoint} + ${interpolationUrl}${healthEndpoint}`,
});
