// Publish Lambda's CloudWatch metrics into the suite's lambda pushgateway.
// Supersedes push-lambda-coldstarts.js, which only covered cold starts.
//
//   node scripts/push-lambda-cloudwatch.js <suite> [windowSeconds]
//
// Called automatically at the end of scripts/loadgen-run.sh.
//
// Authoritative for Lambda whenever it runs more than one sandbox. Each sandbox
// keeps its own in-memory registry and Prometheus reports whichever answers the
// scrape: with two sandboxes app_* reports 23.25 req/s against a true 2.00, and
// 23.36 ms against CloudWatch's 37.70 ms.
//
// Cold starts come from the REPORT line in CloudWatch Logs: Init Duration is not
// published as a metric.

const { execFileSync } = require("child_process");
const http = require("http");

const SUITES = {
  anilove: { fn: "aws-perf-bench-anilove", port: 9094 },
  "csv-processor": { fn: "aws-perf-bench-csv-processor", port: 9194 },
  "thumbnail-generator": { fn: "aws-perf-bench-thumbnail-generator", port: 9294 },
};

const suite = process.argv[2];
const windowSec = Number(process.argv[3] || 3600);
const cfg = SUITES[suite];
if (!cfg) {
  console.error("usage: node scripts/push-lambda-cloudwatch.js <anilove|csv-processor|thumbnail-generator> [windowSeconds]");
  process.exit(1);
}

const modeOnly = process.argv.includes("--mode-only");
const region = process.env.AWS_REGION || "ap-northeast-1";
const endTs = new Date();
const startTs = new Date(endTs.getTime() - windowSec * 1000);
const iso = (d) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

// execFileSync, not a shell: MSYS rewrites the leading / of the log group name.
// An empty stdout is a valid "no data" answer - get-function-concurrency returns
// nothing at all when the function has no reservation - so it maps to {} rather
// than throwing in JSON.parse.
function aws(args) {
  const out = execFileSync("aws", args, { maxBuffer: 64 * 1024 * 1024 }).toString().trim();
  return out === "" ? {} : JSON.parse(out);
}

function metric(name, stats, extended) {
  const args = [
    "cloudwatch", "get-metric-statistics",
    "--region", region,
    "--namespace", "AWS/Lambda",
    "--metric-name", name,
    "--dimensions", `Name=FunctionName,Value=${cfg.fn}`,
    "--start-time", iso(startTs),
    "--end-time", iso(endTs),
    // One datapoint over the window: run-level aggregate.
    "--period", String(Math.max(60, Math.ceil(windowSec / 60) * 60)),
    "--output", "json",
  ];
  if (stats && stats.length) args.push("--statistics", ...stats);
  if (extended && extended.length) args.push("--extended-statistics", ...extended);
  try {
    const r = aws(args);
    const dps = r.Datapoints || [];
    if (!dps.length) return null;
    // Fold multiple periods into one.
    return dps.reduce((acc, d) => {
      acc.Sum = (acc.Sum || 0) + (d.Sum || 0);
      acc.Maximum = Math.max(acc.Maximum || 0, d.Maximum || 0);
      acc.Average = d.Average !== undefined ? d.Average : acc.Average;
      if (d.ExtendedStatistics) acc.p95 = d.ExtendedStatistics.p95;
      return acc;
    }, {});
  } catch (e) {
    console.error("WARN  " + name + ": " + (e.message || e).toString().split("\n")[0]);
    return null;
  }
}

function main() {
const lines = [];
const add = (s) => lines.push(s);

// Mode banner on the dashboard: 1 = capped (Experiment A), -1 = uncapped (B).
let reserved = -1;
try {
  const r = aws([
    "lambda", "get-function-concurrency",
    "--region", region,
    "--function-name", cfg.fn,
    "--output", "json",
  ]);
  reserved = r.ReservedConcurrentExecutions === undefined ? -1 : r.ReservedConcurrentExecutions;
} catch (e) {
  console.error("WARN  could not read reserved concurrency: " + (e.message || e).toString().split("\n")[0]);
}

if (modeOnly) {
  const body = `lambda_reserved_concurrency ${reserved}
`;
  const p = "/metrics/job/lambda-mode/instance/lambda/service/app-instrumented-lambda/environment/production";
  const r = http.request(
    { host: "127.0.0.1", port: cfg.port, path: p, method: "POST",
      headers: { "Content-Type": "text/plain", "Content-Length": Buffer.byteLength(body) } },
    (res) => { res.resume(); console.log("OK    mode=" + reserved + " -> :" + cfg.port + " (http " + res.statusCode + ")"); }
  );
  r.on("error", (e) => { console.error("FAIL  " + e.message); process.exitCode = 1; });
  r.write(body); r.end();
  return;
}

const duration = metric("Duration", ["Average", "Maximum"], ["p95"]);
if (duration) {
  if (duration.Average !== undefined) add(`lambda_cw_duration_ms{stat="avg"} ${duration.Average.toFixed(2)}`);
  if (duration.Maximum !== undefined) add(`lambda_cw_duration_ms{stat="max"} ${duration.Maximum.toFixed(2)}`);
  if (duration.p95 !== undefined) add(`lambda_cw_duration_ms{stat="p95"} ${Number(duration.p95).toFixed(2)}`);
}

const invocations = metric("Invocations", ["Sum"]);
const throttles = metric("Throttles", ["Sum"]);
const errors = metric("Errors", ["Sum"]);
const concurrency = metric("ConcurrentExecutions", ["Maximum"]);

// Publish zeros explicitly: an absent series and a genuine zero look the same.
add(`lambda_cw_invocations ${invocations ? invocations.Sum : 0}`);
add(`lambda_cw_throttles ${throttles ? throttles.Sum : 0}`);
add(`lambda_cw_errors ${errors ? errors.Sum : 0}`);
add(`lambda_cw_concurrency_max ${concurrency ? concurrency.Maximum : 0}`);

// ---- cold starts, from the REPORT line in CloudWatch Logs ----
let durations = [];
try {
  let token = null;
  let messages = [];
  do {
    const args = [
      "logs", "filter-log-events",
      "--region", region,
      "--log-group-name", "/aws/lambda/" + cfg.fn,
      "--start-time", String(startTs.getTime()),
      "--filter-pattern", '"Init Duration"',
      "--output", "json",
    ];
    if (token) args.push("--next-token", token);
    const out = aws(args);
    messages = messages.concat((out.events || []).map((e) => e.message));
    token = out.nextToken || null;
  } while (token && messages.length < 5000);

  durations = messages
    .map((m) => {
      const hit = /Init Duration:\s*([0-9.]+)\s*ms/.exec(m);
      return hit ? Number(hit[1]) : null;
    })
    .filter((v) => v !== null && !Number.isNaN(v))
    .sort((a, b) => a - b);
} catch (e) {
  console.error("WARN  cold starts: " + (e.message || e).toString().split("\n")[0]);
}

const q = (p) => (durations.length ? durations[Math.min(durations.length - 1, Math.floor(p * durations.length))] : 0);
const mean = durations.length ? durations.reduce((a, b) => a + b, 0) / durations.length : 0;

add(`lambda_cold_start_count ${durations.length}`);
add(`lambda_cold_start_duration_ms{stat="mean"} ${mean.toFixed(2)}`);
add(`lambda_cold_start_duration_ms{stat="p50"} ${q(0.5).toFixed(2)}`);
add(`lambda_cold_start_duration_ms{stat="p95"} ${q(0.95).toFixed(2)}`);
add(`lambda_cold_start_duration_ms{stat="max"} ${(durations[durations.length - 1] || 0).toFixed(2)}`);

const body = lines.join("\n") + "\n";
const path =
  "/metrics/job/lambda-cloudwatch/instance/lambda/service/app-instrumented-lambda/environment/production";

const req = http.request(
  { host: "127.0.0.1", port: cfg.port, path, method: "POST",
    headers: { "Content-Type": "text/plain", "Content-Length": Buffer.byteLength(body) } },
  (res) => {
    res.resume();
    const ok = String(res.statusCode).startsWith("2");
    console.log(
      (ok ? "OK    " : "FAIL  ") + cfg.fn +
        `: invocations=${invocations ? invocations.Sum : 0}` +
        `, throttles=${throttles ? throttles.Sum : 0}` +
        `, errors=${errors ? errors.Sum : 0}` +
        `, peak_concurrency=${concurrency ? concurrency.Maximum : 0}` +
        (duration && duration.Average !== undefined ? `, duration_avg=${duration.Average.toFixed(1)}ms` : "") +
        `, cold_starts=${durations.length}` +
        ` -> :${cfg.port} (http ${res.statusCode})`
    );
    if (!ok) process.exitCode = 1;
  }
);
req.on("error", (e) => {
  console.error("FAIL  pushgateway :" + cfg.port + " - " + e.message);
  process.exitCode = 1;
});
req.write(body);
req.end();
}
main();
