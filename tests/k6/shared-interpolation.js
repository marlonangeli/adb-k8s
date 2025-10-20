import http from 'k6/http';
import { check, Trend } from 'k6';

export const options = {
  vus: 30,
  duration: '3m',
  thresholds: {
    http_req_duration: ['p(95)<900'],
    http_req_failed: ['rate<0.01'],
    load_balance_score: ['avg>0.4'],
  },
};

const interpolationUrl = __ENV.INTERPOLATION_BASE_URL;
const scoreMetric = new Trend('load_balance_score');

if (!interpolationUrl) {
  throw new Error('INTERPOLATION_BASE_URL is required');
}

export default function () {
  const res = http.get(`${interpolationUrl}/interpolate`, {
    params: { longitude: -51.16, latitude: -25.09, model: 'kriging' },
  });
  check(res, {
    'status 200': (r) => r.status === 200,
    'has payload': (r) => !!r.body,
  });

  // Proxy metric to validar distribuição: maior variação => maior score.
  scoreMetric.add(res.timings.waiting / (res.timings.duration || 1));
}
