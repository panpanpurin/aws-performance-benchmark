// Capture the Prometheus app_* means for one run, before the stack is torn down.
//
//   node scripts/capture-app-metrics.js anilove 20260810-054832
//   make capture-anilove RUN=20260810-054832
//
// Why this exists. The Artillery reports are client-side and have no notion of
// database wait; the split of total service time into compute and DB wait lives
// only in Prometheus, which runs in the suite's compose stack and dies with it.
// Every repetition ends in a teardown, so the numbers have to reach disk while
// the stack is still up. Emits app-metrics-<run-id>.json next to the reports.
//
// Means, not percentiles: percentiles do not subtract, so P95(total) - P95
// (internal) is not the 95th-percentile database wait. Only means are additive.
// See docs/PAPER-SSCAD-2026.md "Reading the results correctly".

const fs = require("fs");
const http = require("http");
const path = require("path");

const PLATFORMS = ["ec2", "ecs", "lambda"];
// Each suite remaps the shared stack's host ports; see benchmarks/docs/PORTS.md.
const PROM_PORT = { anilove: 9090, "csv-processor": 9190, "thumbnail-generator": 9290 };
const PERIOD_S = 10;

function usage(msg) {
  if (msg) console.error("error: " + msg + "\n");
  console.error(
    "usage: node scripts/capture-app-metrics.js <suite> <run-id> [--phase N] [--trim N] [--prom URL] [--logs DIR]\n" +
      "  --phase  1-indexed phase from test-*.yml (default: longest, the primary)\n" +
      "  --trim   seconds dropped at each window edge (default 10, one Artillery period)\n" +
      "  --prom   Prometheus base URL (default from the suite's mapped port)\n"
  );
  process.exit(1);
}

const argv = process.argv.slice(2);
const flag = (name, def) => {
  const i = argv.indexOf("--" + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
};
const positional = argv.filter((a, i) => !a.startsWith("--") && !(i > 0 && argv[i - 1].startsWith("--")));
const [suite, runId] = positional;
if (!suite || !runId) usage("suite and run-id are required");
if (!PROM_PORT[suite]) usage("unknown suite: " + suite);

const suiteDir = path.join("benchmarks", "suites", suite);
const logsDir = flag("logs", path.join(suiteDir, "artillery", "logs"));
const trim = Number(flag("trim", 10));
const promBase = flag("prom", "http://localhost:" + PROM_PORT[suite]);
const phaseArg = flag("phase", null);

// Same regex as aggregate-runs.js and make-figures.js: the phase block is a flat
// list, so a YAML parser would be a dependency for no gain.
function readPhases() {
  const yml = path.join(suiteDir, "artillery", "test-ec2.yml");
  const text = fs.readFileSync(yml, "utf8");
  const phases = [];
  const re = /^\s*-\s*duration:\s*(\d+)\s*$/gm;
  let m;
  while ((m = re.exec(text)) !== null) {
    const rest = text.slice(m.index + m[0].length, m.index + m[0].length + 200);
    const count = /arrivalCount:\s*(\d+)/.exec(rest);
    phases.push({ duration: Number(m[1]), arrivals: count ? Number(count[1]) : null });
  }
  let elapsed = 0;
  for (const p of phases) {
    p.start = elapsed;
    p.end = elapsed + p.duration;
    elapsed = p.end;
  }
  return phases;
}

// The run's own clock. Anchoring on the report rather than on the run id matters
// because the id is stamped when the script starts, not when load begins.
function readAnchor() {
  for (const p of PLATFORMS) {
    for (const f of [`loadgen-test-${p}-${runId}.json`, `test-${p}-${runId}.json`, `loadgen-pilot-${p}-${runId}.json`]) {
      const full = path.join(logsDir, f);
      if (!fs.existsSync(full)) continue;
      const im = JSON.parse(fs.readFileSync(full, "utf8")).intermediate || [];
      if (im.length) return Number(im[0].period);
    }
  }
  return null;
}

function readCondition() {
  const f = path.join(logsDir, `manifest-${runId}.json`);
  if (!fs.existsSync(f)) return "unknown";
  try {
    const c = JSON.parse(fs.readFileSync(f, "utf8")).config || {};
    const v = c.lambda_reserved_concurrency;
    if (v === null || v === undefined) return "unknown";
    return Number(v) < 0 ? "uncapped" : "capped";
  } catch {
    return "unknown";
  }
}

function query(expr, atEpoch) {
  const body = new URLSearchParams({ query: expr, time: String(atEpoch) }).toString();
  const u = new URL(promBase + "/api/v1/query");
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: u.hostname,
        port: u.port,
        path: u.pathname,
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let s = "";
        res.on("data", (d) => (s += d));
        res.on("end", () => {
          try {
            const j = JSON.parse(s);
            if (j.status !== "success") return reject(new Error(j.error || "prometheus error"));
            const out = {};
            for (const r of j.data.result) out[r.metric.instance] = Number(r.value[1]);
            resolve(out);
          } catch (e) {
            reject(new Error("bad response from " + promBase + ": " + s.slice(0, 120)));
          }
        });
      }
    );
    req.on("error", (e) =>
      reject(new Error("cannot reach Prometheus at " + promBase + " (" + e.message + "). Is make bench-" + suite.replace("-processor", "").replace("-generator", "") + " up?"))
    );
    req.write(body);
    req.end();
  });
}

(async () => {
  const phases = readPhases();
  if (!phases.length) usage("no phases parsed from test-ec2.yml");

  const idx = phaseArg
    ? Number(phaseArg) - 1
    : phases.reduce((best, p, i, a) => (p.duration > a[best].duration ? i : best), 0);
  if (!phases[idx]) usage("phase " + phaseArg + " out of range (1.." + phases.length + ")");
  const phase = phases[idx];

  const t0 = readAnchor();
  if (t0 === null) {
    console.error(`no Artillery report for run ${runId} in ${logsDir}`);
    process.exit(1);
  }

  const startS = Math.round(t0 / 1000) + phase.start + trim;
  const endS = Math.round(t0 / 1000) + phase.end - trim;
  const width = endS - startS;
  if (width <= PERIOD_S) usage("window is " + width + "s after trimming; lower --trim");

  const R = `[${width}s]`;
  // Cold start is not a rate. It is recorded once per container, so the counter
  // is read as an instant value: the total for the container that served the
  // run, not the change across the window. The run window normally contains no
  // cold start at all, because the health check and the 30 s Prometheus scrape
  // reach the function minutes before load starts.
  const [ts, tc, is, ic, cs, cc] = await Promise.all([
    query(`sum by (instance) (increase(app_total_execution_time_seconds_sum${R}))`, endS),
    query(`sum by (instance) (increase(app_total_execution_time_seconds_count${R}))`, endS),
    query(`sum by (instance) (increase(app_internal_processing_time_seconds_sum${R}))`, endS),
    query(`sum by (instance) (increase(app_internal_processing_time_seconds_count${R}))`, endS),
    query(`sum by (instance) (app_cold_start_duration_seconds_sum)`, endS),
    query(`sum by (instance) (app_cold_start_duration_seconds_count)`, endS),
  ]);

  const platforms = {};
  for (const p of PLATFORMS) {
    if (!(p in tc) || !tc[p]) continue;
    const totalMs = (1000 * ts[p]) / tc[p];
    // csv-processor and thumbnail-generator have no database, so the internal
    // series is absent and the split is not defined for them.
    const hasInternal = p in ic && ic[p] > 0;
    const internalMs = hasInternal ? (1000 * is[p]) / ic[p] : null;
    // Absent on EC2 and ECS: recordColdStartOnce is a no-op without the Lambda
    // environment variables, so the series only exists for lambda.
    const hasCold = p in cc && cc[p] > 0;
    platforms[p] = {
      total_ms: +totalMs.toFixed(4),
      internal_ms: internalMs === null ? null : +internalMs.toFixed(4),
      db_wait_ms: internalMs === null ? null : +(totalMs - internalMs).toFixed(4),
      requests: Math.round(tc[p]),
      cold_start_count: hasCold ? Math.round(cc[p]) : 0,
      cold_start_mean_ms: hasCold ? +((1000 * cs[p]) / cc[p]).toFixed(2) : null,
    };
  }

  if (!Object.keys(platforms).length) {
    console.error("no app_* series in the window. Was the stack scraping during the run?");
    process.exit(1);
  }

  const out = {
    suite,
    run_id: runId,
    condition: readCondition(),
    captured_at: new Date().toISOString(),
    phase: {
      index_1based: idx + 1,
      arrivals_per_s: phase.arrivals ? +(phase.arrivals / phase.duration).toFixed(2) : null,
      window_start: new Date(startS * 1000).toISOString(),
      window_end: new Date(endS * 1000).toISOString(),
      window_s: width,
      trim_s: trim,
    },
    platforms,
  };

  const dest = path.join(logsDir, `app-metrics-${runId}.json`);
  fs.writeFileSync(dest, JSON.stringify(out, null, 2) + "\n");

  console.log(`\ncaptured ${suite} ${runId}  (${out.condition}, phase ${idx + 1}, ${width}s window)\n`);
  const pad = (s, n) => String(s).padEnd(n);
  console.log("  " + pad("platform", 10) + pad("total", 11) + pad("compute", 11) + pad("db wait", 11) + pad("requests", 10) + "cold start");
  for (const p of PLATFORMS) {
    const v = platforms[p];
    if (!v) continue;
    const f = (x) => (x === null ? pad("-", 11) : pad(x.toFixed(2) + " ms", 11));
    const cold = v.cold_start_count ? `${v.cold_start_count} x ${v.cold_start_mean_ms} ms` : "-";
    console.log("  " + pad(p, 10) + f(v.total_ms) + f(v.internal_ms) + f(v.db_wait_ms) + pad(v.requests, 10) + cold);
  }
  console.log(`\nwrote ${dest}`);
})().catch((e) => {
  console.error(String(e.message || e));
  process.exit(1);
});
