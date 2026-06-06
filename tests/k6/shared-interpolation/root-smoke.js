import http from "k6/http";
import { check } from "k6";
import {
  createEndpointTags,
  createHttpParams,
  createSummaryHandler,
  getDuration,
  getVus,
  recordResponse,
} from "../lib/k6-common.js";

const interpolationUrl = __ENV.INTERPOLATION_BASE_URL;
const expectedTitle =
  __ENV.INTERPOLATION_EXPECTED_TITLE || "ADB-INTERPOLATION-API";
const service = __ENV.K6_TARGET_SERVICE || "adb-interpolation-api";
const scenario = "shared-root-smoke";
const endpoint = "/";

export const options = {
  noConnectionReuse: true,
  systemTags: ["status", "method", "name", "group", "check", "scenario", "expected_response"],
  vus: getVus(2),
  duration: getDuration("1m"),
  thresholds: {
    http_req_duration: ["p(95)<2000"],
    http_req_failed: ["rate<0.01"],
    [`scenario_success{service:${service},scenario:${scenario}}`]: ["rate>0.99"],
    [`hostname_seen{service:${service},scenario:${scenario}}`]: ["rate>0.99"],
  },
};

if (!interpolationUrl) {
  throw new Error("INTERPOLATION_BASE_URL is required");
}

export default function () {
  const response = http.get(
    `${interpolationUrl}${endpoint}`,
    createHttpParams(service, {
      closeConnection: true,
      tags: createEndpointTags("GET", endpoint),
    })
  );

  const { payload, pod } = recordResponse({
    response,
    service,
    scenario,
    endpoint,
  });

  check(response, {
    "status is 200": (r) => r.status === 200,
    "response has body": (r) => !!r.body,
    "response has title": () => payload?.title === expectedTitle,
    "response has hostname": () => pod !== "unknown",
  });
}

export const handleSummary = createSummaryHandler({
  runName: __ENV.K6_RUN_NAME || "shared-root-smoke",
  scenario,
  service,
  targetUrl: `${interpolationUrl}${endpoint}`,
});
