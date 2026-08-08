// Aggregate Artillery reports across repetitions into per-platform statistics.
//
//   node scripts/aggregate-runs.js csv-processor
//   node scripts/aggregate-runs.js csv-processor --phase 4 --csv out.csv
//   make aggregate-csv
//
// Two-stage analysis, per docs/PAPER-SSCAD-2026.md "How many repetitions".
// Stage 1 computes one number per run over a single phase window. Stage 2 takes
// the median and IQR of those numbers across runs. Raw requests are never pooled
// across runs: a run is the unit of replication, not a request.
//
// Reads benchmarks/suites/<suite>/artillery/logs/*test-<platform>-<stamp>.json.
// Phase boundaries come from the suite's test-<platform>.yml.
//
// LIMITATION, and it must be stated in the paper. Artillery's JSON keeps only a
// summary per 10 s period, not the raw histogram buckets, so a true percentile
// over the phase window cannot be reconstructed. Mean, counts, min and max are
// exact (the mean is count-weighted, and means compose). The p50/p95/p99 columns
// are count-weighted means of the per-period percentiles and are marked approx
// in the output. For exact tail latency use the Prometheus app_* histograms with
// histogram_quantile over the same window.

const fs = require("fs");
const path = require("path");

const PLATFORMS = ["ec2", "ecs", "lambda"];
const PERIOD_S = 10;

function usage(msg) {
  if (msg) console.error("error: " + msg);
  console.error(
    "usage: node scripts/aggregate-runs.js <suite> [--phase N] [--trim N] [--csv FILE] [--logs DIR]\n" +
      "  suite    anilove | csv-processor | thumbnail-generator\n" +
      "  --phase  1-indexed phase from test-*.yml (default: longest, the primary)\n" +
      "  --trim   periods dropped at each window edge (default 1)\n" +
      "  --csv    also write one tidy row per run+platform, for R or scipy\n" +
      "  --logs   read reports from here instead of the suite's logs directory\n" +
      "  --test-on  statistic the Friedman test ranks: mean|p50|p95|p99 (default p50)",
  );
  process.exit(1);
}

const argv = process.argv.slice(2);
const suite = argv[0];
if (!suite || suite.startsWith("--")) usage("suite is required");

function flag(name, fallback) {
  const i = argv.indexOf("--" + name);
  return i === -1 ? fallback : argv[i + 1];
}
const phaseArg = flag("phase", null);
const trim = Number(flag("trim", 1));
const csvOut = flag("csv", null);

const suiteDir = path.join("benchmarks", "suites", suite);
// --logs keeps a trial run out of the campaign's report directory, and lets an
// archived campaign be re-analysed without moving files back.
const logsDir = flag("logs", path.join(suiteDir, "artillery", "logs"));
if (!fs.existsSync(logsDir)) usage("no logs directory at " + logsDir);

// Phases straight out of the committed YAML. Regex rather than a YAML parser so
// the script stays dependency free; the phase block is a stable flat list.
function readPhases(platform) {
  const yml = path.join(suiteDir, "artillery", `test-${platform}.yml`);
  if (!fs.existsSync(yml)) return null;
  const text = fs.readFileSync(yml, "utf8");
  const phases = [];
  const re = /^\s*-\s*duration:\s*(\d+)\s*$/gm;
  let m;
  while ((m = re.exec(text)) !== null) {
    const rest = text.slice(m.index + m[0].length, m.index + m[0].length + 200);
    const count = /arrivalCount:\s*(\d+)/.exec(rest);
    const rate = /arrivalRate:\s*(\d+)/.exec(rest);
    const duration = Number(m[1]);
    phases.push({
      duration,
      arrivals: count ? Number(count[1]) : rate ? Number(rate[1]) * duration : null,
    });
  }
  let elapsed = 0;
  for (const p of phases) {
    p.start = elapsed;
    p.end = elapsed + p.duration;
    p.rate = p.arrivals === null ? null : +(p.arrivals / p.duration).toFixed(1);
    elapsed = p.end;
  }
  return phases;
}

// Experiment A and B differ only by lambda_reserved_concurrency, which
// scripts/run-manifest.sh records per run. Pooling them into one cell would
// average two different conditions. Runs predating the manifest report unknown.
function readCondition(stamp) {
  const f = path.join(logsDir, `manifest-${stamp}.json`);
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

// loadgen-test-ec2-20260804-144650.json and test-ec2-<stamp>.json both match.
function discoverRuns() {
  const runs = new Map();
  for (const f of fs.readdirSync(logsDir)) {
    const m = /^(?:loadgen-)?test-(ec2|ecs|lambda)-(\d{8}-\d{6})\.json$/.exec(f);
    if (!m) continue;
    const [, platform, stamp] = m;
    if (!runs.has(stamp)) runs.set(stamp, {});
    runs.get(stamp)[platform] = path.join(logsDir, f);
  }
  return [...runs.entries()].sort((a, b) => a[0].localeCompare(b[0]));
}

// Periods fully inside [start, end), minus a guard band at each edge. Artillery
// buckets by wall clock, so a period spanning a phase boundary mixes two arrival
// rates and would drag the window statistics toward the neighbouring phase.
function windowPeriods(intermediate, phase) {
  const t0 = Number(intermediate[0].period);
  const inside = intermediate.filter((p) => {
    const s = (Number(p.period) - t0) / 1000;
    return s >= phase.start && s + PERIOD_S <= phase.end;
  });
  return trim > 0 ? inside.slice(trim, inside.length - trim) : inside;
}

function summarise(periods) {
  let requests = 0;
  let weighted = 0;
  let n = 0;
  let min = Infinity;
  let max = -Infinity;
  const codes = {};
  const errors = {};
  const pctSum = { p50: 0, p95: 0, p99: 0 };

  for (const p of periods) {
    for (const [k, v] of Object.entries(p.counters || {})) {
      if (k === "http.requests") requests += v;
      else if (k.startsWith("http.codes.")) codes[k.slice(11)] = (codes[k.slice(11)] || 0) + v;
      else if (k.startsWith("errors.")) errors[k.slice(7)] = (errors[k.slice(7)] || 0) + v;
    }
    const s = (p.summaries || {})["http.response_time"];
    if (!s || !s.count) continue;
    n += s.count;
    weighted += s.mean * s.count;
    min = Math.min(min, s.min);
    max = Math.max(max, s.max);
    for (const q of ["p50", "p95", "p99"]) pctSum[q] += (s[q] ?? 0) * s.count;
  }

  const responses = Object.values(codes).reduce((a, b) => a + b, 0);
  const ok = Object.entries(codes)
    .filter(([c]) => c.startsWith("2"))
    .reduce((a, [, v]) => a + v, 0);
  const errored = Object.values(errors).reduce((a, b) => a + b, 0);
  // Non-2xx responses plus transport failures, over arrivals. Requests that never
  // got a response (ETIMEDOUT) are lost by a responses-only denominator.
  const failed = responses - ok + errored;

  return {
    periods: periods.length,
    requests,
    responses,
    ok,
    failed,
    errorRatePct: requests ? +((failed / requests) * 100).toFixed(3) : null,
    meanMs: n ? +(weighted / n).toFixed(2) : null,
    p50Ms: n ? +(pctSum.p50 / n).toFixed(2) : null,
    p95Ms: n ? +(pctSum.p95 / n).toFixed(2) : null,
    p99Ms: n ? +(pctSum.p99 / n).toFixed(2) : null,
    minMs: Number.isFinite(min) ? min : null,
    maxMs: Number.isFinite(max) ? max : null,
    codes,
    errors,
  };
}

// Type 7, the default in numpy and R. Named so the paper can cite the method.
function quantile(sorted, p) {
  if (!sorted.length) return null;
  if (sorted.length === 1) return sorted[0];
  const h = (sorted.length - 1) * p;
  const lo = Math.floor(h);
  const frac = h - lo;
  const next = sorted[lo + 1] ?? sorted[lo];
  return sorted[lo] + frac * (next - sorted[lo]);
}

// Ranks within one block, ties averaged. Friedman ranks across treatments, so a
// block here is one run and the values are its three platform statistics.
function rankRow(values) {
  const idx = values.map((v, i) => [v, i]).sort((a, b) => a[0] - b[0]);
  const ranks = new Array(values.length);
  let i = 0;
  while (i < idx.length) {
    let j = i;
    while (j + 1 < idx.length && idx[j + 1][0] === idx[i][0]) j++;
    const avg = (i + j + 2) / 2;
    for (let t = i; t <= j; t++) ranks[idx[t][1]] = avg;
    i = j + 1;
  }
  return ranks;
}

// Friedman. The three platforms are loaded concurrently in one time window, so a
// run is a block and the observations within it are paired rather than
// independent. Conover's tie-corrected form.
//
// blocks: array of arrays, one per run, each holding k treatment values in a
// fixed platform order. Returns null when there is nothing to test.
function friedman(blocks) {
  const n = blocks.length;
  const k = blocks[0]?.length ?? 0;
  if (n < 2 || k < 2) return null;

  const ranked = blocks.map(rankRow);
  const rankSums = new Array(k).fill(0);
  let A = 0;
  for (const row of ranked) {
    for (let j = 0; j < k; j++) {
      rankSums[j] += row[j];
      A += row[j] * row[j];
    }
  }
  // C is Conover's correction term; the numerator subtracts n*C, the denominator
  // subtracts C. Without ties this reduces to 12/(n k (k+1)) * sum(R^2) - 3n(k+1).
  const C = (n * k * (k + 1) * (k + 1)) / 4;
  const sumRsq = rankSums.reduce((s, r) => s + r * r, 0);
  if (A - C === 0) return { n, k, chi2: 0, df: k - 1, p: 1, meanRanks: rankSums.map((r) => r / n), degenerate: true };

  const chi2 = ((k - 1) * (sumRsq - n * C)) / (A - C);
  const df = k - 1;
  // Closed form for df=2 only. Other df needs an incomplete gamma this script
  // does not carry, so the statistic is reported without a p-value.
  const p = df === 2 ? Math.exp(-chi2 / 2) : null;

  // Nemenyi critical difference on mean ranks (Demsar 2006). q values are the
  // studentized range at alpha divided by sqrt(2), tabulated per k.
  const Q05 = { 2: 1.96, 3: 2.343, 4: 2.569, 5: 2.728 };
  const cd = Q05[k] ? Q05[k] * Math.sqrt((k * (k + 1)) / (6 * n)) : null;

  return { n, k, chi2, df, p, meanRanks: rankSums.map((r) => r / n), cd };
}

function across(values) {
  const v = values.filter((x) => x !== null && Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const r = (x) => (x === null ? null : +x.toFixed(2));
  return { n: v.length, median: r(quantile(v, 0.5)), q1: r(quantile(v, 0.25)), q3: r(quantile(v, 0.75)), min: r(v[0]), max: r(v[v.length - 1]) };
}

const runs = discoverRuns();
if (!runs.length) usage("no test-<platform>-<stamp>.json reports in " + logsDir);

const refPhases = readPhases("ec2") || readPhases("ecs") || readPhases("lambda");
if (!refPhases || !refPhases.length) usage("could not read phases from " + suiteDir);

// The primary operating point is the longest phase unless told otherwise.
let phaseIdx;
if (phaseArg !== null) {
  phaseIdx = Number(phaseArg) - 1;
  if (!refPhases[phaseIdx]) usage(`--phase ${phaseArg} out of range, ${refPhases.length} phases`);
} else {
  phaseIdx = refPhases.reduce((best, p, i) => (p.duration > refPhases[best].duration ? i : best), 0);
}

console.log(`\nsuite   ${suite}`);
console.log(`runs    ${runs.length}   (${runs.map(([s]) => s).join(", ")})`);
console.log("phases  " + refPhases.map((p, i) => `${i + 1}:${p.duration}s@${p.rate ?? "?"}/s`).join("  "));
const phase = refPhases[phaseIdx];
console.log(
  `window  phase ${phaseIdx + 1}, ${phase.start}-${phase.end}s at ${phase.rate ?? "?"} req/s` +
    (phaseArg === null ? " (longest, auto)" : "") +
    `, ${trim} period(s) trimmed per edge\n`,
);

// Stage 1: one row per run and platform.
const perRun = [];
for (const [stamp, files] of runs) {
  for (const platform of PLATFORMS) {
    if (!files[platform]) continue;
    let report;
    try {
      report = JSON.parse(fs.readFileSync(files[platform], "utf8"));
    } catch (e) {
      console.error(`skip ${path.basename(files[platform])}: ${e.message}`);
      continue;
    }
    const im = report.intermediate || [];
    if (!im.length) {
      console.error(`skip ${path.basename(files[platform])}: no intermediate periods`);
      continue;
    }
    const phases = readPhases(platform) || refPhases;
    const activePhase = phases[phaseIdx] || phase;
    const periods = windowPeriods(im, activePhase);
    if (!periods.length) {
      console.error(`skip ${path.basename(files[platform])}: window empty, run shorter than the phase?`);
      continue;
    }
    const row = { stamp, platform, condition: readCondition(stamp), ...summarise(periods) };

    // A report predating a phase change is windowed with today's boundaries and
    // silently lands on the wrong operating point. Compare the arrival rate the
    // window actually saw against what the YAML asks for.
    if (activePhase.rate) {
      row.observedRate = +(row.requests / (row.periods * PERIOD_S)).toFixed(1);
      row.rateMismatch = Math.abs(row.observedRate - activePhase.rate) / activePhase.rate > 0.1;
    }
    perRun.push(row);
  }
}

if (!perRun.length) {
  console.error("no usable runs after windowing");
  process.exit(1);
}

// Runs from a superseded phase schedule are not replicates of the current one.
// Excluded by default: pooling them would mix two operating points in one cell.
const mismatched = perRun.filter((r) => r.rateMismatch);
const allowMismatch = argv.includes("--allow-mismatch");
if (mismatched.length && !allowMismatch) {
  console.log("EXCLUDED, arrival rate does not match the committed schedule:");
  for (const r of mismatched) {
    console.log(`  ${r.stamp} ${r.platform.padEnd(6)} saw ${r.observedRate} req/s, phase asks ${phase.rate}`);
  }
  console.log("  These predate the current test-*.yml. --allow-mismatch to include anyway.\n");
}
const usable = allowMismatch ? perRun : perRun.filter((r) => !r.rateMismatch);
if (!usable.length) {
  console.error("every run mismatched the committed phase schedule");
  process.exit(1);
}

const pad = (s, w) => String(s ?? "-").padStart(w);
console.log("PER RUN                                              mean    p50*    p95*    p99*");
console.log("run              plat   condition    reqs   err%       ms      ms      ms      ms");
for (const r of usable) {
  console.log(
    `${r.stamp}  ${r.platform.padEnd(6)} ${r.condition.padEnd(9)}${pad(r.requests, 7)}${pad(r.errorRatePct, 7)}` +
      `${pad(r.meanMs, 9)}${pad(r.p50Ms, 8)}${pad(r.p95Ms, 8)}${pad(r.p99Ms, 8)}`,
  );
}

// Stage 2: median and IQR across runs, the numbers that go in the paper. Split
// by condition: capped is Experiment A, uncapped is B, and they do not pool.
const conditions = [...new Set(usable.map((r) => r.condition))].sort();
for (const condition of conditions) {
  const label = { capped: "capped, Experiment A", uncapped: "uncapped, Experiment B" }[condition] || "condition unknown, no manifest";
  console.log(`\nACROSS RUNS   ${label}   median [Q1, Q3]`);
  console.log("plat     n         mean ms              p95* ms              p99* ms            err %");
  for (const platform of PLATFORMS) {
    const rows = usable.filter((r) => r.platform === platform && r.condition === condition);
    if (!rows.length) continue;
    const cell = (key) => {
      const a = across(rows.map((r) => r[key]));
      return a ? `${a.median} [${a.q1}, ${a.q3}]` : "-";
    };
    console.log(
      `${platform.padEnd(6)}${pad(rows.length, 3)}   ${cell("meanMs").padEnd(20)} ${cell("p95Ms").padEnd(20)} ${cell("p99Ms").padEnd(19)} ${cell("errorRatePct")}`,
    );
  }
}

// Friedman per condition. Only complete blocks count: a run missing a platform
// cannot be ranked against the others and is dropped rather than imputed.
const TEST_KEYS = { mean: "meanMs", p50: "p50Ms", p95: "p95Ms", p99: "p99Ms" };
const testOn = flag("test-on", "p50");
const testKey = TEST_KEYS[testOn];
if (!testKey) usage(`--test-on ${testOn}, expected one of ${Object.keys(TEST_KEYS).join(", ")}`);

for (const condition of conditions) {
  const rows = usable.filter((r) => r.condition === condition);
  const stamps = [...new Set(rows.map((r) => r.stamp))].sort();
  const present = PLATFORMS.filter((p) => rows.some((r) => r.platform === p));
  const blocks = [];
  const dropped = [];
  for (const stamp of stamps) {
    const vals = present.map((p) => rows.find((r) => r.stamp === stamp && r.platform === p)?.[testKey]);
    if (vals.every((v) => v !== undefined && v !== null && Number.isFinite(v))) blocks.push(vals);
    else dropped.push(stamp);
  }

  console.log(`\nFRIEDMAN   ${condition}, on per-run ${testOn}`);
  const f = friedman(blocks);
  if (!f) {
    console.log(`  not enough complete blocks (${blocks.length}); needs 2+ runs with all platforms.`);
    continue;
  }
  console.log(`  blocks (runs) n=${f.n}, treatments k=${f.k}: ${present.join(", ")}`);
  console.log(`  mean ranks: ${present.map((p, i) => `${p} ${f.meanRanks[i].toFixed(2)}`).join("   ")}   (1 = fastest)`);
  const pStr = f.p === null ? "n/a for df!=2" : f.p < 0.0001 ? "< 0.0001" : f.p.toFixed(4);
  console.log(`  chi2 = ${f.chi2.toFixed(3)}, df = ${f.df}, p = ${pStr}`);
  if (f.cd) {
    console.log(`  Nemenyi CD at alpha=0.05: ${f.cd.toFixed(2)} rank units; pairs differing by more than that separate.`);
  }
  if (dropped.length) console.log(`  dropped incomplete runs: ${dropped.join(", ")}`);
  if (f.n < 5) console.log("  n is small; the chi-square approximation is asymptotic, treat p as indicative.");

  // Effect size. A ratio of medians survives a reviewer asking "how much", which
  // a p-value does not.
  const meds = present.map((p) => across(rows.filter((r) => r.platform === p).map((r) => r[testKey]))?.median);
  const base = Math.min(...meds.filter(Number.isFinite));
  if (Number.isFinite(base) && base > 0) {
    console.log(`  ratio of medians: ${present.map((p, i) => `${p} ${(meds[i] / base).toFixed(2)}x`).join("   ")}`);
  }
}

console.log("\n* p50/p95/p99 are count-weighted means of the per-period percentiles,");
console.log("  not exact window percentiles. See the header of this script.");
if (usable.some((r) => r.errorRatePct > 0)) {
  console.log("\nnon-zero error rate present: report it beside latency, never separately.");
  for (const r of usable.filter((x) => x.failed > 0)) {
    const codes = Object.entries(r.codes)
      .filter(([c]) => !c.startsWith("2"))
      .map(([c, v]) => `${c}x${v}`)
      .join(" ");
    const errs = Object.entries(r.errors).map(([e, v]) => `${e}x${v}`).join(" ");
    console.log(`  ${r.stamp} ${r.platform}: ${[codes, errs].filter(Boolean).join(" ")}`);
  }
}
for (const condition of conditions) {
  const n = Math.max(...PLATFORMS.map((p) => usable.filter((r) => r.platform === p && r.condition === condition).length));
  if (n < 10) console.log(`\nn = ${n} per platform (${condition}). Target is 10 capped; 3 is the defensible floor.`);
}
if (conditions.includes("unknown")) {
  console.log("runs marked unknown predate scripts/run-manifest.sh and carry no record of");
  console.log("lambda_reserved_concurrency. Label them by hand or leave them out.");
}

if (csvOut) {
  const cols = ["run", "platform", "condition", "requests", "error_rate_pct", "mean_ms", "p50_ms", "p95_ms", "p99_ms", "min_ms", "max_ms", "periods"];
  const lines = [cols.join(",")];
  for (const r of usable) {
    lines.push(
      [r.stamp, r.platform, r.condition, r.requests, r.errorRatePct, r.meanMs, r.p50Ms, r.p95Ms, r.p99Ms, r.minMs, r.maxMs, r.periods].join(","),
    );
  }
  fs.writeFileSync(csvOut, lines.join("\n") + "\n");
  console.log(`\nwrote ${csvOut}  (${usable.length} rows, one per run and platform)`);
}
