import http from "k6/http";
import { check, sleep } from "k6";
import {
  createEndpointTags,
  createHttpParams,
  createRscriptResponseCallback,
  createSummaryHandler,
  getDuration,
  getVus,
  isExpectedRscriptOutcome,
  isRscriptBackpressure,
  recordRscriptResponse,
} from "../lib/k6-common.js";

const interpolationUrl = __ENV.INTERPOLATION_BASE_URL;
const service = __ENV.K6_TARGET_SERVICE || "adb-interpolation-api";
const scenario = "shared-idw-grid";
const endpoint = "/idw/to-grid";

export const options = {
  systemTags: ["status", "method", "name", "group", "check", "scenario", "expected_response"],
  vus: getVus(5),
  duration: getDuration("1m"),
  thresholds: {
    http_req_duration: ["p(95)<2000"],
    http_req_failed: ["rate<0.01"],
    [`scenario_success{service:${service},scenario:${scenario}}`]: ["rate>0.99"],
  },
};

if (!interpolationUrl) {
  throw new Error("INTERPOLATION_BASE_URL is required");
}

const payload = open("./payloads/idw_grid.json");

export default function () {
  const response = http.post(
    `${interpolationUrl}${endpoint}`,
    payload,
    createHttpParams(service, {
      headers: {
        "Content-Type": "application/json",
      },
      responseCallback: createRscriptResponseCallback(),
      tags: createEndpointTags("POST", endpoint),
    })
  );

  recordRscriptResponse({
    response,
    service,
    scenario,
    endpoint,
  });

  check(response, {
    "status is 201 or expected Rscript backpressure": (r) => isExpectedRscriptOutcome(r),
    "response has body when completed": (r) => isRscriptBackpressure(r) || !!r.body,
  });

  sleep(1);
}

export const handleSummary = createSummaryHandler({
  runName: __ENV.K6_RUN_NAME || "shared-idw-grid",
  scenario,
  service,
  targetUrl: `${interpolationUrl}${endpoint}`,
});
