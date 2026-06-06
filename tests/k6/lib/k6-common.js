import http from 'k6/http';
import { Counter, Rate, Trend } from 'k6/metrics';

export const scenarioRequests = new Counter('scenario_requests');
export const scenarioRequestDuration = new Trend('scenario_request_duration', true);
export const scenarioRequestWaiting = new Trend('scenario_request_waiting', true);
export const scenarioSuccess = new Rate('scenario_success');
export const rscriptBackpressureWarnings = new Counter('rscript_backpressure_warnings');
export const hostnameSeen = new Rate('hostname_seen');
export const podHits = new Counter('pod_hits');
export const podRequestDuration = new Trend('pod_request_duration', true);
export const podRequestSuccess = new Rate('pod_request_success');

const DEFAULT_RSCRIPT_BUSY_STATUS = 503;

const trackedEnvKeys = [
  'K6_RUN_NAME',
  'K6_TARGET_SERVICE',
  'K6_DURATION',
  'K6_VUS',
  'K6_RATE',
  'K6_PREALLOCATED_VUS',
  'K6_MAX_VUS',
  'TARGET_VUS',
  'INTERPOLATION_BASE_URL',
  'TENANT_API_BASE_URL',
  'INTERPOLATION_EXPECTED_TITLE',
];

const fallbackRunName = 'local';

const isFiniteNumber = value => Number.isFinite(value);

const toNumber = (value, fallback) => {
  const parsed = Number(value);
  return isFiniteNumber(parsed) ? parsed : fallback;
};

export const getRscriptBusyStatus = () => toNumber(
  __ENV.INTERPOLATION_RSCRIPT_BUSY_STATUS,
  DEFAULT_RSCRIPT_BUSY_STATUS
);

export const createRscriptResponseCallback = (expectedStatus = 201) => http.expectedStatuses(
  expectedStatus,
  getRscriptBusyStatus()
);

export const isRscriptBackpressure = response => response.status === getRscriptBusyStatus();

export const isExpectedRscriptOutcome = (response, expectedStatus = 201) => (
  response.status === expectedStatus || isRscriptBackpressure(response)
);

const toMilliseconds = value => (isFiniteNumber(value) ? `${value.toFixed(2)} ms` : 'n/a');

const toRate = value => (isFiniteNumber(value) ? `${(value * 100).toFixed(2)}%` : 'n/a');

const extractMetricValues = (data, metricName) => data.metrics?.[metricName]?.values || {};

const summarizeMetric = (data, metricName) => {
  const values = extractMetricValues(data, metricName);
  return {
    count: values.count ?? 'n/a',
    rate: values.rate ?? 'n/a',
    avg: values.avg ?? 'n/a',
    p90: values['p(90)'] ?? 'n/a',
    p95: values['p(95)'] ?? 'n/a',
    p99: values['p(99)'] ?? 'n/a',
    max: values.max ?? 'n/a',
  };
};

const getSummaryMetadata = meta => ({
  ...meta,
  generatedAt: new Date().toISOString(),
  env: trackedEnvKeys.reduce((result, key) => {
    if (__ENV[key]) {
      result[key] = __ENV[key];
    }

    return result;
  }, {}),
});

const formatSummaryText = (data, meta) => {
  const httpDuration = summarizeMetric(data, 'http_req_duration');
  const httpFailed = extractMetricValues(data, 'http_req_failed');
  const backpressureWarnings = summarizeMetric(data, 'rscript_backpressure_warnings');
  const iterations = summarizeMetric(data, 'iterations');
  const requests = summarizeMetric(data, 'http_reqs');
  const metadata = getSummaryMetadata(meta);

  return [
    `k6 run: ${metadata.runName || fallbackRunName}`,
    `scenario: ${metadata.scenario}`,
    `service: ${metadata.service}`,
    `targetUrl: ${metadata.targetUrl}`,
    `generatedAt: ${metadata.generatedAt}`,
    '',
    'Overall metrics',
    `- iterations: ${iterations.count}`,
    `- http requests: ${requests.count}`,
    `- request rate: ${requests.rate}`,
    `- request duration avg: ${toMilliseconds(httpDuration.avg)}`,
    `- request duration p95: ${toMilliseconds(httpDuration.p95)}`,
    `- request duration p99: ${toMilliseconds(httpDuration.p99)}`,
    `- request duration max: ${toMilliseconds(httpDuration.max)}`,
    `- failed request rate: ${toRate(httpFailed.rate)}`,
    `- expected Rscript backpressure warnings: ${backpressureWarnings.count}`,
  ].join('\n');
};

const formatSummaryMarkdown = (data, meta) => {
  const httpDuration = summarizeMetric(data, 'http_req_duration');
  const httpFailed = extractMetricValues(data, 'http_req_failed');
  const backpressureWarnings = summarizeMetric(data, 'rscript_backpressure_warnings');
  const requests = summarizeMetric(data, 'http_reqs');
  const iterations = summarizeMetric(data, 'iterations');
  const metadata = getSummaryMetadata(meta);

  return [
    '# k6 In-Cluster Summary',
    '',
    '## Run Metadata',
    '',
    '| Field | Value |',
    '|---|---|',
    `| Run name | ${metadata.runName || fallbackRunName} |`,
    `| Scenario | ${metadata.scenario} |`,
    `| Service | ${metadata.service} |`,
    `| Target URL | ${metadata.targetUrl} |`,
    `| Generated at | ${metadata.generatedAt} |`,
    '',
    '## Overall Metrics',
    '',
    '| Metric | Value |',
    '|---|---:|',
    `| Iterations | ${iterations.count} |`,
    `| HTTP requests | ${requests.count} |`,
    `| HTTP request rate | ${requests.rate} |`,
    `| HTTP duration avg | ${toMilliseconds(httpDuration.avg)} |`,
    `| HTTP duration p90 | ${toMilliseconds(httpDuration.p90)} |`,
    `| HTTP duration p95 | ${toMilliseconds(httpDuration.p95)} |`,
    `| HTTP duration p99 | ${toMilliseconds(httpDuration.p99)} |`,
    `| HTTP duration max | ${toMilliseconds(httpDuration.max)} |`,
    `| Failed request rate | ${toRate(httpFailed.rate)} |`,
    `| Expected Rscript backpressure warnings | ${backpressureWarnings.count} |`,
    '',
    '> Detailed per-pod distribution and charts are generated by scripts/k6-artifact-report.py after the in-cluster job finishes.',
  ].join('\n');
};

const safeJson = response => {
  try {
    return response.json();
  } catch (error) {
    return null;
  }
};

const extractHostname = payload => {
  if (!payload || typeof payload !== 'object') {
    return null;
  }

  if (typeof payload.hostname === 'string' && payload.hostname.length > 0) {
    return payload.hostname;
  }

  if (payload.data && typeof payload.data.hostname === 'string' && payload.data.hostname.length > 0) {
    return payload.data.hostname;
  }

  return null;
};

export const getDuration = fallback => __ENV.K6_DURATION || fallback;

export const getVus = fallback => toNumber(__ENV.K6_VUS, fallback);

export const getTargetVus = fallback => toNumber(__ENV.TARGET_VUS, fallback);

export const getRate = fallback => toNumber(__ENV.K6_RATE, fallback);

export const getPreAllocatedVus = fallback => toNumber(__ENV.K6_PREALLOCATED_VUS, fallback);

export const getMaxVus = fallback => toNumber(__ENV.K6_MAX_VUS, fallback);

export const createEndpointTags = (method, endpoint, extra = {}) => ({
  ...extra,
  endpoint,
  name: `${method} ${endpoint}`,
});

export const createHttpParams = (service, extra = {}) => {
  const baseHeaders = {
    'X-K6-Run-Name': __ENV.K6_RUN_NAME || fallbackRunName,
    'X-K6-Service': service,
  };

  const headers = {
    ...baseHeaders,
    ...(extra.headers || {}),
  };

  if (extra.closeConnection) {
    headers.Connection = 'close';
  }

  return {
    ...extra,
    headers,
    tags: {
      service,
      run_name: __ENV.K6_RUN_NAME || fallbackRunName,
      ...(extra.tags || {}),
    },
  };
};

export const recordResponse = ({ response, service, scenario, endpoint, isSuccess }) => {
  const tags = { service, scenario, endpoint };
  const ok = typeof isSuccess === 'boolean' ? isSuccess : response.status < 400;
  const payload = safeJson(response);
  const pod = extractHostname(payload);

  scenarioRequests.add(1, tags);
  scenarioRequestDuration.add(response.timings.duration, tags);
  scenarioRequestWaiting.add(response.timings.waiting, tags);
  scenarioSuccess.add(ok, tags);
  hostnameSeen.add(Boolean(pod), tags);

  if (pod) {
    const podTags = { ...tags, pod };
    podHits.add(1, podTags);
    podRequestDuration.add(response.timings.duration, podTags);
    podRequestSuccess.add(ok, podTags);
  }

  return {
    payload,
    pod: pod || 'unknown',
  };
};

export const recordRscriptResponse = ({ response, service, scenario, endpoint, expectedStatus = 201 }) => {
  const isBackpressure = isRscriptBackpressure(response);

  if (isBackpressure) {
    rscriptBackpressureWarnings.add(1, {
      service,
      scenario,
      endpoint,
      status: String(response.status),
    });
  }

  return recordResponse({
    response,
    service,
    scenario,
    endpoint,
    isSuccess: isExpectedRscriptOutcome(response, expectedStatus),
  });
};

export const createSummaryHandler = meta => data => {
  const metadata = getSummaryMetadata(meta);

  return {
    '/results/summary.json': JSON.stringify(data, null, 2),
    '/results/metadata.json': JSON.stringify(metadata, null, 2),
    '/results/summary.txt': formatSummaryText(data, metadata),
    '/results/summary.md': formatSummaryMarkdown(data, metadata),
  };
};
