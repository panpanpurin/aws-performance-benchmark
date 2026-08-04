// Push an Artillery JSON report into the suite's pushgateways.
//
//   node scripts/push-artillery-report.js <suite> <stamp>
//
// Called automatically at the end of scripts/loadgen-run.sh.
//
// The Artillery publish-metrics plugin pushes to localhost, which the in-region
// generator cannot reach. The run already downloads the JSON report, which holds
// the same counters. Metric and label names match the plugin's so the existing
// panels work unchanged.

const fs = require("fs");
const path = require("path");
const http = require("http");

const [suite, stamp] = process.argv.slice(2);
if (!suite || !stamp) {
  console.error("usage: node scripts/push-artillery-report.js <suite> <stamp>");
  process.exit(1);
}

// Same allocation as benchmarks/docs/PORTS.md.
const PORTS = {
  anilove: { ecs: 9092, ec2: 9093, lambda: 9094 },
  "csv-processor": { ecs: 9192, ec2: 9193, lambda: 9194 },
  "thumbnail-generator": { ecs: 9292, ec2: 9293, lambda: 9294 },
};

const ports = PORTS[suite];
if (!ports) {
  console.error("unknown suite: " + suite);
  process.exit(1);
}

const logsDir = path.join("benchmarks", "suites", suite, "artillery", "logs");

function post(port, job, labels, body) {
  return new Promise((resolve) => {
    let p = "/metrics/job/" + encodeURIComponent(job);
    for (const [k, v] of Object.entries(labels)) {
      p += "/" + encodeURIComponent(k) + "/" + encodeURIComponent(v);
    }
    const req = http.request(
      { host: "127.0.0.1", port, path: p, method: "POST",
        headers: { "Content-Type": "text/plain", "Content-Length": Buffer.byteLength(body) } },
      (res) => {
        res.resume();
        resolve(res.statusCode);
      }
    );
    req.on("error", (e) => resolve("ERR " + e.message));
    req.write(body);
    req.end();
  });
}

(async () => {
  let pushed = 0;
  for (const platform of ["ec2", "ecs", "lambda"]) {
    const candidates = fs
      .readdirSync(logsDir)
      .filter((f) => f.includes(platform) && f.includes(stamp) && f.endsWith(".json"));
    if (!candidates.length) {
      console.log("SKIP  no JSON report for " + platform + " (" + stamp + ")");
      continue;
    }
    const j = JSON.parse(fs.readFileSync(path.join(logsDir, candidates[0]), "utf8"));
    const a = j.aggregate || {};
    const c = a.counters || {};
    const s = a.summaries || {};
    const r = a.rates || {};

    const rt = s["http.response_time"] || {};
    const total = c["http.requests"] || 0;
    const ok = c["http.codes.200"] || 0;
    // anilove's CRUD flow returns 201 and 204, so count every 2xx.
    const twoxx = Object.entries(c)
      .filter(([k]) => /^http\.codes\.2\d\d$/.test(k))
      .reduce((n, [, v]) => n + v, 0);

    const lines = [];
    const push = (name, metric, value) => {
      if (value === undefined || value === null || Number.isNaN(value)) return;
      lines.push(`${name}{metric="${metric}"} ${value}`);
    };

    // Counted separately: the dashboard derived both 4xx and 5xx from
    // (1 - 2xx/total), so 502 throttles were reported as client errors.
    const classCount = (cls) =>
      Object.entries(c)
        .filter(([k]) => new RegExp(`^http\\.codes\\.${cls}\\d\\d$`).test(k))
        .reduce((n, [, v]) => n + v, 0);
    const fourxx = classCount(4);
    const fivexx = classCount(5);

    push("artillery_rates", "http_request_rate", r["http.request_rate"]);
    push("artillery_summaries", "http_response_time_mean", rt.mean);
    push("artillery_summaries", "http_response_time_median", rt.median);
    push("artillery_summaries", "http_response_time_p95", rt.p95);
    push("artillery_summaries", "http_response_time_p99", rt.p99);
    push("artillery_summaries", "http_response_time_count", total);
    push("artillery_summaries", "http_response_time_2xx_count", twoxx);
    push("artillery_summaries", "http_response_time_4xx_count", fourxx);
    push("artillery_summaries", "http_response_time_5xx_count", fivexx);
    push("artillery_counters", "http_requests", total);
    push("artillery_counters", "http_codes_200", ok);

    if (!lines.length) {
      console.log("SKIP  " + platform + ": report had no usable counters");
      continue;
    }

    const body = lines.join("\n") + "\n";
    const code = await post(ports[platform], "artillery-" + platform,
      { instance: platform, service: "artillery-" + platform, environment: "production" }, body);
    console.log(
      (String(code).startsWith("2") ? "OK    " : "FAIL  ") +
        platform + " -> :" + ports[platform] + "  (" + lines.length + " series, http " + code + ")"
    );
    if (String(code).startsWith("2")) pushed++;
  }
  console.log("\n" + pushed + "/3 platform reports pushed for " + suite + " " + stamp);
  if (!pushed) process.exitCode = 1;
})();
