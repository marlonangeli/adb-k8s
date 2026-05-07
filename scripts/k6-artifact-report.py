#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import html
import json
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from statistics import mean


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None

    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]

    rank = (len(ordered) - 1) * pct
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    weight = rank - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def load_json(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def load_metric_lines(path: Path) -> list[dict]:
    if not path.exists():
        return []

    items = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        items.append(json.loads(line))
    return items


def duration_to_seconds(value: str) -> int:
    if not value:
        return 1800

    suffix = value[-1]
    raw_number = value[:-1] if suffix in "smhd" else value
    try:
        number = float(raw_number)
    except ValueError:
        return 1800

    multipliers = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    return int(number * multipliers.get(suffix, 1))


def prometheus_api(base_url: str, path: str, params: dict) -> dict:
    query = urllib.parse.urlencode(params, doseq=True)
    url = f"{base_url.rstrip('/')}{path}?{query}"
    with urllib.request.urlopen(url, timeout=10) as response:
        payload = json.loads(response.read().decode("utf-8"))

    if payload.get("status") != "success":
        raise RuntimeError(payload)

    return payload.get("data", {})


def prometheus_query(base_url: str, query: str, evaluation_time: float | None = None) -> list[dict]:
    params = {"query": query}
    if evaluation_time:
        params["time"] = f"{evaluation_time:.3f}"
    return prometheus_api(base_url, "/api/v1/query", params).get("result", [])


def prometheus_query_range(base_url: str, query: str, start: float, end: float, step: str = "5s") -> list[dict]:
    return prometheus_api(
        base_url,
        "/api/v1/query_range",
        {"query": query, "start": f"{start:.3f}", "end": f"{end:.3f}", "step": step},
    ).get("result", [])


def prometheus_series(base_url: str, match: str, start: float, end: float) -> list[dict]:
    return prometheus_api(
        base_url,
        "/api/v1/series",
        {"match[]": match, "start": f"{start:.3f}", "end": f"{end:.3f}"},
    )


def prom_label_value(value: str) -> str:
    return json.dumps(value)


def scalar_from_result(result: list[dict]) -> float | None:
    if not result:
        return None

    try:
        return float(result[0]["value"][1])
    except (KeyError, IndexError, TypeError, ValueError):
        return None


def vector_map(result: list[dict], labels: list[str]) -> dict[tuple[str, ...], float]:
    values: dict[tuple[str, ...], float] = {}
    for item in result:
        metric = item.get("metric", {})
        key = tuple(metric.get(label, "") for label in labels)
        try:
            values[key] = float(item["value"][1])
        except (KeyError, IndexError, TypeError, ValueError):
            continue
    return values


def select_metric_name(metric_names: set[str], prefix: str, suffix: str) -> str | None:
    candidates = sorted(name for name in metric_names if name.startswith(prefix) and name.endswith(suffix))
    return candidates[0] if candidates else None


def counter_total_and_rate(base_url: str, metric_name: str, selector: str, start_time: float, end_time: float) -> tuple[float | None, float | None]:
    result = prometheus_query_range(base_url, f"sum({metric_name}{selector})", start_time, end_time)
    if not result:
        return None, None

    values = []
    for timestamp, raw_value in result[0].get("values", []):
        try:
            values.append((float(timestamp), float(raw_value)))
        except (TypeError, ValueError):
            continue

    if not values:
        return None, None

    first_ts = values[0][0]
    last_ts = values[-1][0]
    total = max(value for _, value in values)
    elapsed = max(last_ts - first_ts, 1)
    return total, total / elapsed


def collect_prometheus_summary(base_url: str, test_id: str, window: str) -> dict:
    if not base_url or not test_id:
        return {}

    end_time = time.time()
    start_time = end_time - duration_to_seconds(window)
    selector = f'{{testid={prom_label_value(test_id)}}}'
    metric_names = {
        item.get("__name__", "")
        for item in prometheus_series(base_url, f'{{__name__=~"k6_.*",testid={prom_label_value(test_id)}}}', start_time, end_time)
    }

    duration_prefix = "k6_http_req_duration"
    avg_metric = select_metric_name(metric_names, duration_prefix, "_avg")
    p95_metric = select_metric_name(metric_names, duration_prefix, "_p95")
    p99_metric = select_metric_name(metric_names, duration_prefix, "_p99")
    max_metric = select_metric_name(metric_names, duration_prefix, "_max")
    request_count, request_rate = counter_total_and_rate(base_url, "k6_http_reqs_total", selector, start_time, end_time)

    metrics = {
        "http_reqs": {
            "values": {
                "count": request_count,
                "rate": request_rate,
            }
        },
        "http_req_failed": {
            "values": {
                "rate": scalar_from_result(prometheus_query(base_url, f"avg(avg_over_time(k6_http_req_failed_rate{selector}[{window}]))", end_time)),
            }
        },
        "http_req_duration": {"values": {}},
    }

    for output_name, metric_name in {
        "avg": avg_metric,
        "p(95)": p95_metric,
        "p(99)": p99_metric,
        "max": max_metric,
    }.items():
        if metric_name:
            metrics["http_req_duration"]["values"][output_name] = scalar_from_result(
                prometheus_query(base_url, f"avg(avg_over_time({metric_name}{selector}[{window}]))", end_time)
            )

    return {"metrics": metrics, "prometheusMetricNames": sorted(metric_names)}


def collect_prometheus_pod_rows(base_url: str, test_id: str, window: str) -> list[dict]:
    if not base_url or not test_id:
        return []

    end_time = time.time()
    start_time = end_time - duration_to_seconds(window)
    label_names = ["service", "scenario", "endpoint", "pod"]
    selector = f'{{testid={prom_label_value(test_id)}}}'
    metric_names = {
        item.get("__name__", "")
        for item in prometheus_series(base_url, f'{{__name__=~"k6_pod_.*",testid={prom_label_value(test_id)}}}', start_time, end_time)
    }

    hits = vector_map(
        prometheus_query(
            base_url,
            f"sum by (service,scenario,endpoint,pod) (max_over_time(k6_pod_hits_total{selector}[{window}]))",
            end_time,
        ),
        label_names,
    )

    duration_prefix = "k6_pod_request_duration"
    avg_metric = select_metric_name(metric_names, duration_prefix, "_avg")
    p95_metric = select_metric_name(metric_names, duration_prefix, "_p95")
    max_metric = select_metric_name(metric_names, duration_prefix, "_max")

    def grouped_avg(metric_name: str | None) -> dict[tuple[str, ...], float]:
        if not metric_name:
            return {}
        return vector_map(
            prometheus_query(
                base_url,
                f"avg by (service,scenario,endpoint,pod) (avg_over_time({metric_name}{selector}[{window}]))",
                end_time,
            ),
            label_names,
        )

    avg_values = grouped_avg(avg_metric)
    p95_values = grouped_avg(p95_metric)
    max_values = grouped_avg(max_metric)
    success_values = vector_map(
        prometheus_query(
            base_url,
            f"avg by (service,scenario,endpoint,pod) (avg_over_time(k6_pod_request_success_rate{selector}[{window}]))",
            end_time,
        ),
        label_names,
    )

    totals_by_service: dict[str, float] = defaultdict(float)
    for (service, _, _, _), count in hits.items():
        totals_by_service[service] += count

    rows = []
    for key, count in sorted(hits.items()):
        service, scenario, endpoint, pod = key
        total = totals_by_service.get(service, 0) or 1
        rows.append(
            {
                "service": service,
                "scenario": scenario,
                "endpoint": endpoint,
                "pod": pod,
                "hits": int(round(count)),
                "share": count / total,
                "avg_ms": avg_values.get(key),
                "p95_ms": p95_values.get(key),
                "max_ms": max_values.get(key),
                "success_rate": success_values.get(key),
            }
        )

    return rows


def format_number(value, decimals: int = 2) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, str):
        return value
    return f"{value:.{decimals}f}"


def format_percentage(value) -> str:
    if value is None:
        return "n/a"
    return f"{value * 100:.2f}%"


def summary_metric(summary: dict, metric_name: str) -> dict:
    metric = summary.get("metrics", {}).get(metric_name, {})
    return metric.get("values", {})


def collect_pod_rows(metric_lines: list[dict]) -> list[dict]:
    hits: dict[tuple[str, str, str, str], float] = defaultdict(float)
    durations: dict[tuple[str, str, str, str], list[float]] = defaultdict(list)
    successes: dict[tuple[str, str, str, str], list[float]] = defaultdict(list)

    for item in metric_lines:
        if item.get("type") != "Point":
            continue

        metric_name = item.get("metric")
        payload = item.get("data", {})
        tags = payload.get("tags", {})
        key = (
            tags.get("service", "unknown-service"),
            tags.get("scenario", "unknown-scenario"),
            tags.get("endpoint", "unknown-endpoint"),
            tags.get("pod", "unknown-pod"),
        )

        value = payload.get("value")

        if metric_name == "pod_hits":
            hits[key] += float(value or 0)
        elif metric_name == "pod_request_duration":
            durations[key].append(float(value or 0))
        elif metric_name == "pod_request_success":
            successes[key].append(float(value or 0))

    totals_by_service: dict[str, float] = defaultdict(float)
    for (service, _, _, _), count in hits.items():
        totals_by_service[service] += count

    rows = []
    for key, count in sorted(hits.items()):
        service, scenario, endpoint, pod = key
        latency_values = durations.get(key, [])
        success_values = successes.get(key, [])
        total = totals_by_service.get(service, 0) or 1
        rows.append(
            {
                "service": service,
                "scenario": scenario,
                "endpoint": endpoint,
                "pod": pod,
                "hits": int(count),
                "share": count / total,
                "avg_ms": mean(latency_values) if latency_values else None,
                "p95_ms": percentile(latency_values, 0.95),
                "max_ms": max(latency_values) if latency_values else None,
                "success_rate": mean(success_values) if success_values else None,
            }
        )

    return rows


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def build_markdown(metadata: dict, summary: dict, pod_rows: list[dict]) -> str:
    http_duration = summary_metric(summary, "http_req_duration")
    http_failed = summary_metric(summary, "http_req_failed")
    http_requests = summary_metric(summary, "http_reqs")
    pod_axis = ", ".join(json.dumps(row["pod"]) for row in pod_rows)
    hit_values = ", ".join(str(row["hits"]) for row in pod_rows)

    lines = [
        "# k6 TCC Evidence Report",
        "",
        "## Run Metadata",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Run name | {metadata.get('runName', 'n/a')} |",
        f"| Scenario | {metadata.get('scenario', 'n/a')} |",
        f"| Service | {metadata.get('service', 'n/a')} |",
        f"| Target URL | {metadata.get('targetUrl', 'n/a')} |",
        f"| Prometheus testid | `{metadata.get('testId', 'n/a')}` |",
        f"| Snapshot scope | {metadata.get('scope', 'n/a')} |",
        f"| Generated at | {metadata.get('generatedAt', 'n/a')} |",
        "",
        "## Overall Metrics",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| HTTP requests | {http_requests.get('count', 'n/a')} |",
        f"| HTTP request rate | {http_requests.get('rate', 'n/a')} |",
        f"| HTTP duration avg | {format_number(http_duration.get('avg'))} ms |",
        f"| HTTP duration p95 | {format_number(http_duration.get('p(95)'))} ms |",
        f"| HTTP duration p99 | {format_number(http_duration.get('p(99)'))} ms |",
        f"| HTTP duration max | {format_number(http_duration.get('max'))} ms |",
        f"| Failed request rate | {format_percentage(http_failed.get('rate'))} |",
        "",
    ]

    prometheus_error = metadata.get("prometheus", {}).get("error")
    if prometheus_error:
        lines.extend(["> Prometheus query warning: " + prometheus_error, ""])

    if pod_rows:
        lines.extend(
            [
                "## Pod Distribution",
                "",
                "| Service | Pod | Hits | Share | Avg ms | P95 ms | Max ms | Success rate |",
                "|---|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for row in pod_rows:
            lines.append(
                f"| {row['service']} | `{row['pod']}` | {row['hits']} | {row['share'] * 100:.2f}% | {format_number(row['avg_ms'])} | {format_number(row['p95_ms'])} | {format_number(row['max_ms'])} | {format_percentage(row['success_rate'])} |"
            )

        lines.extend(
            [
                "",
                "## Mermaid Chart",
                "",
                "```mermaid",
                "xychart-beta",
                f"  title \"Pod hit distribution - {metadata.get('service', 'service')}\"",
                f"  x-axis [{pod_axis}]",
                "  y-axis \"Hits\" 0 --> " + str(max(row['hits'] for row in pod_rows) + 1),
                f"  bar [{hit_values}]",
                "```",
            ]
        )
    else:
        lines.extend([
            "## Pod Distribution",
            "",
            "No hostname-aware pod metrics were recorded for this scenario.",
        ])

    return "\n".join(lines) + "\n"


def build_svg_bars(pod_rows: list[dict]) -> str:
    if not pod_rows:
        return "<p>No pod-level chart available for this scenario.</p>"

    bar_width = 120
    height = 260
    chart_height = 180
    max_hits = max(row["hits"] for row in pod_rows) or 1
    width = max(400, bar_width * len(pod_rows))
    bars = []

    for index, row in enumerate(pod_rows):
        x = 40 + index * bar_width
        bar_height = int((row["hits"] / max_hits) * chart_height)
        y = 20 + chart_height - bar_height
        bars.append(
            f'<rect x="{x}" y="{y}" width="64" height="{bar_height}" fill="#2563eb" rx="6" />'
        )
        bars.append(
            f'<text x="{x + 32}" y="{y - 8}" text-anchor="middle" font-size="12">{row["hits"]}</text>'
        )
        bars.append(
            f'<text x="{x + 32}" y="{height - 26}" text-anchor="middle" font-size="11">{html.escape(row["pod"])}</text>'
        )
        bars.append(
            f'<text x="{x + 32}" y="{height - 10}" text-anchor="middle" font-size="11">{row["share"] * 100:.1f}%</text>'
        )

    return (
        f'<svg viewBox="0 0 {width} {height}" width="100%" height="{height}" xmlns="http://www.w3.org/2000/svg">'
        f'<line x1="24" y1="20" x2="24" y2="200" stroke="#111827" stroke-width="2" />'
        f'<line x1="24" y1="200" x2="{width - 16}" y2="200" stroke="#111827" stroke-width="2" />'
        f'{"".join(bars)}'
        '</svg>'
    )


def build_html(metadata: dict, summary: dict, pod_rows: list[dict]) -> str:
    http_duration = summary_metric(summary, "http_req_duration")
    http_failed = summary_metric(summary, "http_req_failed")
    http_requests = summary_metric(summary, "http_reqs")

    table_rows = "".join(
        "<tr>"
        f"<td>{html.escape(row['service'])}</td>"
        f"<td><code>{html.escape(row['pod'])}</code></td>"
        f"<td>{row['hits']}</td>"
        f"<td>{row['share'] * 100:.2f}%</td>"
        f"<td>{format_number(row['avg_ms'])}</td>"
        f"<td>{format_number(row['p95_ms'])}</td>"
        f"<td>{format_number(row['max_ms'])}</td>"
        f"<td>{format_percentage(row['success_rate'])}</td>"
        "</tr>"
        for row in pod_rows
    )

    return f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <title>k6 TCC Evidence Report</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 24px; color: #111827; }}
    table {{ border-collapse: collapse; width: 100%; margin-bottom: 24px; }}
    th, td {{ border: 1px solid #d1d5db; padding: 8px 10px; text-align: left; }}
    th {{ background: #eff6ff; }}
    code {{ background: #f3f4f6; padding: 2px 4px; border-radius: 4px; }}
    .cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; margin-bottom: 24px; }}
    .card {{ border: 1px solid #d1d5db; border-radius: 10px; padding: 14px; background: #f9fafb; }}
    .label {{ font-size: 12px; color: #6b7280; text-transform: uppercase; letter-spacing: 0.06em; }}
    .value {{ font-size: 24px; font-weight: 700; margin-top: 6px; }}
  </style>
</head>
<body>
  <h1>k6 TCC Evidence Report</h1>
  <p><strong>Run:</strong> {html.escape(metadata.get('runName', 'n/a'))} · <strong>Scenario:</strong> {html.escape(metadata.get('scenario', 'n/a'))} · <strong>Service:</strong> {html.escape(metadata.get('service', 'n/a'))}</p>
  <p><strong>Target:</strong> <code>{html.escape(metadata.get('targetUrl', 'n/a'))}</code> · <strong>testid:</strong> <code>{html.escape(metadata.get('testId', 'n/a'))}</code></p>
  <div class=\"cards\">
    <div class=\"card\"><div class=\"label\">HTTP Requests</div><div class=\"value\">{http_requests.get('count', 'n/a')}</div></div>
    <div class=\"card\"><div class=\"label\">Avg Duration</div><div class=\"value\">{format_number(http_duration.get('avg'))} ms</div></div>
    <div class=\"card\"><div class=\"label\">P95 Duration</div><div class=\"value\">{format_number(http_duration.get('p(95)'))} ms</div></div>
    <div class=\"card\"><div class=\"label\">Failed Requests</div><div class=\"value\">{format_percentage(http_failed.get('rate'))}</div></div>
  </div>

  <h2>Overall Metrics</h2>
  <table>
    <tr><th>Metric</th><th>Value</th></tr>
    <tr><td>HTTP request rate</td><td>{http_requests.get('rate', 'n/a')}</td></tr>
    <tr><td>P99 duration</td><td>{format_number(http_duration.get('p(99)'))} ms</td></tr>
    <tr><td>Max duration</td><td>{format_number(http_duration.get('max'))} ms</td></tr>
    <tr><td>Generated at</td><td>{html.escape(metadata.get('generatedAt', 'n/a'))}</td></tr>
  </table>

  <h2>Pod Distribution</h2>
  {build_svg_bars(pod_rows)}
  <table>
    <tr><th>Service</th><th>Pod</th><th>Hits</th><th>Share</th><th>Avg ms</th><th>P95 ms</th><th>Max ms</th><th>Success rate</th></tr>
    {table_rows or '<tr><td colspan="8">No hostname-aware pod metrics were recorded for this scenario.</td></tr>'}
  </table>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate TCC-ready reports from k6 in-cluster artifacts.")
    parser.add_argument("--run-dir", required=True, help="Directory containing k6 artifacts")
    parser.add_argument("--test-id", default="", help="k6 testid tag used in Prometheus")
    parser.add_argument("--run-name", default="", help="k6 run name")
    parser.add_argument("--service", default="", help="Target service name")
    parser.add_argument("--target-url", default="", help="Target URL used by k6")
    parser.add_argument("--scope", default="", help="Snapshot/test scope")
    parser.add_argument("--prometheus-url", default="", help="Prometheus base URL for querying k6 remote-write metrics")
    parser.add_argument("--prometheus-window", default="30m", help="PromQL range window for this run")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    summary = load_json(run_dir / "summary-export.json", {})
    metadata = load_json(run_dir / "metadata.json", {})
    metric_lines = load_metric_lines(run_dir / "metrics.json")
    pod_rows = collect_pod_rows(metric_lines)

    prometheus_error = None
    if args.prometheus_url and args.test_id:
        try:
            prometheus_summary = collect_prometheus_summary(args.prometheus_url, args.test_id, args.prometheus_window)
            if prometheus_summary:
                summary = prometheus_summary
            prometheus_rows = collect_prometheus_pod_rows(args.prometheus_url, args.test_id, args.prometheus_window)
            if prometheus_rows:
                pod_rows = prometheus_rows
        except Exception as error:  # noqa: BLE001 - report generation should preserve local artifacts on query failure.
            prometheus_error = str(error)

    metadata = {
        "runName": args.run_name or metadata.get("runName", "n/a"),
        "scenario": metadata.get("scenario", args.scope or "n/a"),
        "service": args.service or metadata.get("service", "n/a"),
        "targetUrl": args.target_url or metadata.get("targetUrl", "n/a"),
        "testId": args.test_id or metadata.get("testId", "n/a"),
        "scope": args.scope or metadata.get("scope", "n/a"),
        "generatedAt": metadata.get("generatedAt") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prometheus": {
            "url": args.prometheus_url,
            "window": args.prometheus_window,
            "error": prometheus_error,
        },
    }

    write_csv(
        run_dir / "pod-distribution.csv",
        pod_rows,
        ["service", "scenario", "endpoint", "pod", "hits", "share", "avg_ms", "p95_ms", "max_ms", "success_rate"],
    )

    overview_rows = [
        {"metric": "http_requests", "value": summary_metric(summary, "http_reqs").get("count")},
        {"metric": "http_request_rate", "value": summary_metric(summary, "http_reqs").get("rate")},
        {"metric": "http_req_duration_avg_ms", "value": summary_metric(summary, "http_req_duration").get("avg")},
        {"metric": "http_req_duration_p95_ms", "value": summary_metric(summary, "http_req_duration").get("p(95)")},
        {"metric": "http_req_duration_p99_ms", "value": summary_metric(summary, "http_req_duration").get("p(99)")},
        {"metric": "http_req_failed_rate", "value": summary_metric(summary, "http_req_failed").get("rate")},
    ]
    write_csv(run_dir / "overview.csv", overview_rows, ["metric", "value"])

    markdown = build_markdown(metadata, summary, pod_rows)
    (run_dir / "paper-report.md").write_text(markdown, encoding="utf-8")
    (run_dir / "paper-report.html").write_text(build_html(metadata, summary, pod_rows), encoding="utf-8")
    (run_dir / "report-index.json").write_text(
        json.dumps(
            {
                "metadata": metadata,
                "podDistributionRows": pod_rows,
                "files": sorted(path.name for path in run_dir.iterdir() if path.is_file()),
                "prometheusMetricNames": summary.get("prometheusMetricNames", []),
            },
            indent=2,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
