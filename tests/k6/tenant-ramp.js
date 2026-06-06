import http from 'k6/http';
import { check, fail, group, sleep } from 'k6';
import {
  createHttpParams,
  createSummaryHandler,
  getTargetVus,
  recordResponse,
} from './lib/k6-common.js';

const baseUrl = __ENV.TENANT_API_BASE_URL;
const targetVus = getTargetVus(50);
const service = __ENV.K6_TARGET_SERVICE || 'tenant-api';
const scenario = 'tenant-ramp';
const password = __ENV.ADB_API_K6_PASSWORD || 'adb-k6-1234';
const expiresIn = __ENV.ADB_API_EXPIRES_IN || '100000';

const jsonHeaders = {
  'Content-Type': 'application/json',
};

export const options = {
  discardResponseBodies: true,
  systemTags: ['status', 'method', 'name', 'group', 'check', 'scenario', 'expected_response'],
  stages: [
    { duration: '2m', target: Math.ceil(targetVus * 0.25) },
    { duration: '3m', target: Math.ceil(targetVus * 0.75) },
    { duration: '5m', target: targetVus },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<800', 'p(99)<1200'],
    http_req_failed: ['rate<0.02'],
    checks: ['rate>0.98'],
    [`scenario_success{service:${service},scenario:${scenario}}`]: ['rate>0.98'],
  },
};

if (!baseUrl) {
  throw new Error('TENANT_API_BASE_URL is required');
}

const suffix = label => `${label}-${Date.now()}-${__VU}-${__ITER}`;

const parseJson = response => {
  try {
    return response.json();
  } catch (error) {
    return null;
  }
};

const request = (method, path, body, token, tags = {}, extra = {}) => {
  const metricEndpoint = tags.endpoint || path;
  const payload = body ? JSON.stringify(body) : null;
  const responseOptions = extra.keepBody ? { responseType: 'text' } : {};
  const response = http.request(
    method,
    `${baseUrl}${path}`,
    payload,
    createHttpParams(service, {
      ...responseOptions,
      headers: {
        ...jsonHeaders,
        ...(extra.headers || {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      tags: {
        ...tags,
        endpoint: metricEndpoint,
        name: `${method} ${metricEndpoint}`,
      },
    })
  );

  recordResponse({
    response,
    service,
    scenario,
    endpoint: metricEndpoint,
  });

  return response;
};

export function setup() {
  const userSuffix = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
  const email = `k6+${userSuffix}@adb.com`;
  const personPayload = {
    name: `ADB K6 ${userSuffix}`,
    email,
    password,
    birth: '2000-01-01',
    phone: `459${String(userSuffix).slice(-8).padStart(8, '0')}`,
  };

  const personResponse = request('POST', '/person', personPayload, null, {
    endpoint: '/person',
    endpoint_group: 'auth-bootstrap',
  }, {
    keepBody: true,
  });
  const person = parseJson(personResponse);

  check(personResponse, {
    'create person 201': response => response.status === 201,
    'create person returns id': () => Boolean(person?.id),
  });

  if (!person?.id) {
    fail(`failed to create k6 user: status=${personResponse.status}`);
  }

  const authResponse = request('POST', '/auth', { username: email, password }, null, {
    endpoint: '/auth',
    endpoint_group: 'auth-bootstrap',
  }, {
    headers: { 'Expires-in': expiresIn },
    keepBody: true,
  });

  const auth = parseJson(authResponse);
  const token = auth?.token;

  check(authResponse, {
    'auth 200': response => response.status === 200,
    'auth returns token': () => Boolean(token),
  });

  if (!token) {
    fail(`failed to authenticate k6 user: status=${authResponse.status}`);
  }

  return { token, userId: person.id, email };
}

const createCompanyPayload = () => ({
  name: `K6 Company ${suffix('company')}`,
  state: 'PR',
  city: 'Medianeira',
});

const updateCompanyPayload = () => ({
  name: `K6 Company Updated ${suffix('company-updated')}`,
  state: 'PR',
  city: 'Medianeira',
});

const createEmployeePayload = () => ({
  name: `K6 Employee ${suffix('employee')}`,
});

const updateEmployeePayload = () => ({
  name: `K6 Employee Updated ${suffix('employee-updated')}`,
});

const runCrud = ({ resource, createPayload, updatePayload, token }) => {
  const tag = { endpoint_group: `${resource}-crud` };

  const createResponse = request('POST', `/${resource}`, createPayload(), token, {
    ...tag,
    endpoint: `/${resource}`,
  }, {
    keepBody: true,
  });
  const created = parseJson(createResponse);
  const id = created?.id;
  check(createResponse, {
    [`${resource} create 201`]: response => response.status === 201,
    [`${resource} create returns id`]: () => Boolean(id),
  });

  if (!id) {
    return;
  }

  const listResponse = request('GET', `/${resource}?shared=false&page=0&size=50`, null, token, {
    ...tag,
    endpoint: `/${resource}`,
  });
  check(listResponse, {
    [`${resource} list 200`]: response => response.status === 200,
  });

  const getResponse = request('GET', `/${resource}/${id}`, null, token, {
    ...tag,
    endpoint: `/${resource}/{id}`,
  });
  check(getResponse, {
    [`${resource} get 200`]: response => response.status === 200,
  });

  const updateResponse = request('PUT', `/${resource}/${id}`, updatePayload(), token, {
    ...tag,
    endpoint: `/${resource}/{id}`,
  });
  check(updateResponse, {
    [`${resource} update 200`]: response => response.status === 200,
  });

  const deleteResponse = request('DELETE', `/${resource}/${id}`, null, token, {
    ...tag,
    endpoint: `/${resource}/{id}`,
  });
  check(deleteResponse, {
    [`${resource} delete ok`]: response => response.status === 200 || response.status === 204,
  });
};

export default function (data) {
  group('company-crud', () => {
    runCrud({
      resource: 'company',
      createPayload: createCompanyPayload,
      updatePayload: updateCompanyPayload,
      token: data.token,
    });
  });

  group('employee-crud', () => {
    runCrud({
      resource: 'employee',
      createPayload: createEmployeePayload,
      updatePayload: updateEmployeePayload,
      token: data.token,
    });
  });

  sleep(0.5);
}

export const handleSummary = createSummaryHandler({
  runName: __ENV.K6_RUN_NAME || 'tenant-ramp',
  scenario,
  service,
  targetUrl: `${baseUrl}/company + ${baseUrl}/employee`,
});
