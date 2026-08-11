// End-to-end latency split into in-app compute, database wait and everything
// outside the application.
//
//   node scripts/make-db-wait-figure.js anilove
//   make figure-split-anilove
//
// Reads every app-metrics-<run-id>.json written by capture-app-metrics.js, pairs
// it with the Artillery report for the same window, and plots the median across
// runs of three components per platform:
//
//   compute   in-app, excluding database time
//   db wait   in-app total minus internal, so the time spent on Postgres
//   overhead  client mean minus in-app total: TLS, the ALB, the network, and for
//             Lambda the invocation path. EC2 and ECS carry the same network and
//             ALB, so they are the control for that term.
//
// The point of the figure is that for an I/O-bound workload the compute model is
// the smallest term. The database split is AniLove-specific; csv-processor and
// thumbnail-generator have no database and would show two components.
//
// Means, not percentiles. Percentiles do not subtract, so neither the wait nor
// the overhead can be formed from them. The bar is the sum of three medians,
// which is not identical to the median total; the whisker gives the IQR of the
// per-run client mean so the spread is still visible. Say so in the caption.
//
// Capped runs only by default. Under uncapped Lambda the app_* means are biased
// toward the answering container's lifetime rather than the query window, so the
// decomposition is not valid there. See docs/PAPER-SSCAD-2026.md.

const fs = require("fs");
const path = require("path");

const PLATFORMS = ["ec2", "ecs", "lambda"];
const LABEL = { ec2: "EC2", ecs: "ECS", lambda: "Lambda" };
// Two components, not three platforms, so the palette encodes the split. Both
// clear the contrast floor against white and stay distinct in grayscale, helped
// by the hatch on the second segment.
const C_COMPUTE = "#2a78d6";
const C_WAIT = "#eb6834";
const C_OVER = "#8a8f98";

// End-to-end mean the client saw, over the same trimmed window. Artillery keeps
// a summary per 10 s period, so the window mean is the count-weighted mean of
// the period means: exact for a mean, unlike a percentile.
function clientMean(runId, platform, phase) {
  for (const f of [`loadgen-test-${platform}-${runId}.json`, `test-${platform}-${runId}.json`]) {
    const full = path.join(logsDir, f);
    if (!fs.existsSync(full)) continue;
    const im = JSON.parse(fs.readFileSync(full, "utf8")).intermediate || [];
    if (!im.length) return null;
    const t0 = Number(im[0].period);
    let w = 0;
    let n = 0;
    for (const per of im) {
      const s = (Number(per.period) - t0) / 1000;
      if (s < phase.start + TRIM_S || s + PERIOD_S > phase.end - TRIM_S) continue;
      const sm = (per.summaries || {})["http.response_time"];
      const c = (per.counters || {})["http.requests"] || 0;
      if (sm && c) {
        w += sm.mean * c;
        n += c;
      }
    }
    return n ? w / n : null;
  }
  return null;
}

function usage(msg) {
  if (msg) console.error("error: " + msg + "\n");
  console.error(
    "usage: node scripts/make-db-wait-figure.js <suite> [--condition capped|uncapped|all] [--logs DIR]\n"
  );
  process.exit(1);
}

const argv = process.argv.slice(2);
const flag = (n, d) => {
  const i = argv.indexOf("--" + n);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};
const suite = argv.find((a) => !a.startsWith("--") && argv.indexOf(a) === 0);
if (!suite) usage("suite is required");

const suiteDir = path.join("benchmarks", "suites", suite);
const logsDir = flag("logs", path.join(suiteDir, "artillery", "logs"));
const condition = flag("condition", "capped");
if (!fs.existsSync(logsDir)) usage("no logs directory at " + logsDir);

const median = (a) => {
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
// Same convention as aggregate-runs.js: lower half excludes the median for odd n.
const quartiles = (a) => {
  if (a.length < 2) return [null, null];
  const s = [...a].sort((x, y) => x - y);
  const h = s.length >> 1;
  return [median(s.slice(0, h)), median(s.slice(s.length % 2 ? h + 1 : h))];
};

const files = fs.readdirSync(logsDir).filter((f) => /^app-metrics-\d{8}-\d{6}\.json$/.test(f));
if (!files.length) {
  console.error(`no app-metrics-*.json in ${logsDir}. Run capture-app-metrics.js after each run.`);
  process.exit(1);
}

// The committed primary phase. A capture taken on a different phase, or at a
// rate the schedule no longer uses, is a pilot or a superseded calibration run
// and is not a repetition. Same 10% rule as aggregate-runs.js.
function committedPrimary() {
  const text = fs.readFileSync(path.join(suiteDir, "artillery", "test-ec2.yml"), "utf8");
  const ph = [];
  const re = /^\s*-\s*duration:\s*(\d+)\s*$/gm;
  let m;
  while ((m = re.exec(text)) !== null) {
    const rest = text.slice(m.index + m[0].length, m.index + m[0].length + 200);
    const c = /arrivalCount:\s*(\d+)/.exec(rest);
    ph.push({ duration: Number(m[1]), arrivals: c ? Number(c[1]) : 0 });
  }
  if (!ph.length) return null;
  let elapsed = 0;
  for (const p of ph) {
    p.start = elapsed;
    p.end = elapsed + p.duration;
    elapsed = p.end;
  }
  let bi = 0;
  ph.forEach((p, i) => {
    if (p.duration > ph[bi].duration) bi = i;
  });
  return { index_1based: bi + 1, rate: ph[bi].arrivals / ph[bi].duration, start: ph[bi].start, end: ph[bi].end };
}

// Must match capture-app-metrics.js, or the client window and the Prometheus
// window would not describe the same requests.
const PERIOD_S = 10;
const TRIM_S = 10;

const primary = committedPrimary();
const runs = [];
const offSchedule = [];
for (const f of files) {
  const j = JSON.parse(fs.readFileSync(path.join(logsDir, f), "utf8"));
  if (condition !== "all" && j.condition !== condition) continue;
  if (primary && j.phase) {
    const wrongPhase = j.phase.index_1based !== primary.index_1based;
    const r = j.phase.arrivals_per_s;
    const wrongRate = r === null || r === undefined || Math.abs(r - primary.rate) / primary.rate > 0.1;
    if (wrongPhase || wrongRate) {
      offSchedule.push(`${j.run_id} (phase ${j.phase.index_1based}, ${r} arr/s)`);
      continue;
    }
  }
  runs.push(j);
}
if (offSchedule.length) console.log(`\nnot repetitions, excluded: ${offSchedule.join(", ")}`);
if (!runs.length) {
  console.error(`no ${condition} runs among ${files.length} capture(s). Try --condition all.`);
  process.exit(1);
}

// A run-platform below this covers only part of its window and is excluded.
const MIN_COVERAGE = Number(flag("min-coverage", 0.9));
const MAX_COVERAGE = Number(flag("max-coverage", 1.1));
// Only anilove has a database. For the stateless suites the same quantity,
// total minus internal, is the framework and adapter cost around the work.
const MID_LABEL = suite === "anilove" ? "database wait" : "framework + adapter";
const dropped = [];
const stats = {};
for (const p of PLATFORMS) {
  const comp = [];
  const wait = [];
  const over = [];
  const total = [];
  for (const r of runs) {
    const v = r.platforms[p];
    if (!v || v.internal_ms === null) continue;
    // Partial windows are not comparable with whole ones. Written by
    // capture-app-metrics.js; usually a Lambda environment recycled mid-run.
    if (v.scrape_coverage !== null && v.scrape_coverage !== undefined && (v.scrape_coverage < MIN_COVERAGE || v.scrape_coverage > MAX_COVERAGE)) {
      dropped.push(`${r.run_id} ${p} ${(100 * v.scrape_coverage).toFixed(0)}%`);
      continue;
    }
    // Everything the request spent outside the application: TLS, the ALB, the
    // network, and for Lambda the invocation path. EC2 and ECS carry the same
    // network and ALB, so they are the control for that term.
    const cm = primary ? clientMean(r.run_id, p, primary) : null;
    if (cm === null) continue;
    comp.push(v.internal_ms);
    wait.push(v.db_wait_ms);
    over.push(Math.max(0, cm - v.total_ms));
    total.push(cm);
  }
  if (!comp.length) continue;
  const [q1, q3] = quartiles(total);
  stats[p] = { n: comp.length, compute: median(comp), wait: median(wait), over: median(over), total: median(total), q1, q3 };
}
const present = PLATFORMS.filter((p) => stats[p]);
if (!present.length) {
  console.error("no platform has an internal-time series. This figure only applies to anilove.");
  process.exit(1);
}

// Platforms can differ when one is dropped for coverage, so the label is a
// range rather than a single n that would overstate the thinner cell.
const nMin = Math.min(...present.map((p) => stats[p].n));
const nMax = Math.max(...present.map((p) => stats[p].n));
const nRuns = nMax;
const nLabel = nMin === nMax ? `n=${nMax}` : `n=${nMin}-${nMax}`;
const top = Math.max(...present.map((p) => Math.max(stats[p].compute + stats[p].wait + stats[p].over, stats[p].q3 || 0)));
const yTop = Math.ceil((top * 1.18) / 5) * 5;

// ---------------------------------------------------------------- SVG
const W = 620;
const H = 400;
const M = { l: 64, r: 20, t: 34, b: 78 };
const PW = W - M.l - M.r;
const PH = H - M.t - M.b;
const bw = Math.min(88, PW / (present.length * 1.9));
const y = (v) => M.t + PH - (v / yTop) * PH;
const xc = (i) => M.l + (PW / present.length) * (i + 0.5);

const ticks = [];
const step = yTop <= 5 ? 1 : yTop <= 12 ? 2 : 5;
for (let v = 0; v <= yTop + 1e-9; v += step) ticks.push(+v.toFixed(3));

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");
const svg = [];
svg.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="Helvetica, Arial, sans-serif">`);
svg.push(`<defs><pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">` +
  `<rect width="6" height="6" fill="${C_WAIT}"/><line x1="0" y1="0" x2="0" y2="6" stroke="#ffffff" stroke-width="2" opacity="0.55"/></pattern></defs>`);
svg.push(`<rect width="${W}" height="${H}" fill="#ffffff"/>`);
svg.push(`<text x="${M.l}" y="20" font-size="13" font-weight="600" fill="#111">End-to-end latency split, ${esc(suite)} (${esc(condition)}, ${nLabel})</text>`);

for (const t of ticks) {
  svg.push(`<line x1="${M.l}" y1="${y(t).toFixed(1)}" x2="${M.l + PW}" y2="${y(t).toFixed(1)}" stroke="#e6e6e6" stroke-width="1"/>`);
  svg.push(`<text x="${M.l - 8}" y="${(y(t) + 4).toFixed(1)}" font-size="11" fill="#555" text-anchor="end">${t}</text>`);
}
svg.push(`<text x="16" y="${M.t + PH / 2}" font-size="12" fill="#333" text-anchor="middle" transform="rotate(-90 16 ${M.t + PH / 2})">mean time per request (ms)</text>`);
svg.push(`<line x1="${M.l}" y1="${M.t + PH}" x2="${M.l + PW}" y2="${M.t + PH}" stroke="#888" stroke-width="1"/>`);

present.forEach((p, i) => {
  const s = stats[p];
  const x = xc(i) - bw / 2;
  const hC = (s.compute / yTop) * PH;
  const hW = (s.wait / yTop) * PH;
  const hO = (s.over / yTop) * PH;
  const stack = s.compute + s.wait + s.over;
  svg.push(`<rect x="${x.toFixed(1)}" y="${y(s.compute).toFixed(1)}" width="${bw.toFixed(1)}" height="${hC.toFixed(1)}" fill="${C_COMPUTE}"/>`);
  svg.push(`<rect x="${x.toFixed(1)}" y="${y(s.compute + s.wait).toFixed(1)}" width="${bw.toFixed(1)}" height="${hW.toFixed(1)}" fill="url(#hatch)"/>`);
  svg.push(`<rect x="${x.toFixed(1)}" y="${y(stack).toFixed(1)}" width="${bw.toFixed(1)}" height="${hO.toFixed(1)}" fill="${C_OVER}"/>`);
  svg.push(`<rect x="${x.toFixed(1)}" y="${y(stack).toFixed(1)}" width="${bw.toFixed(1)}" height="${(hC + hW + hO).toFixed(1)}" fill="none" stroke="#33333322"/>`);
  if (s.q1 !== null && s.q3 !== null && s.q3 > s.q1) {
    const cx = xc(i);
    svg.push(`<line x1="${cx}" y1="${y(s.q1).toFixed(1)}" x2="${cx}" y2="${y(s.q3).toFixed(1)}" stroke="#222" stroke-width="1.4"/>`);
    for (const q of [s.q1, s.q3])
      svg.push(`<line x1="${cx - 9}" y1="${y(q).toFixed(1)}" x2="${cx + 9}" y2="${y(q).toFixed(1)}" stroke="#222" stroke-width="1.4"/>`);
  }
  svg.push(`<text x="${xc(i)}" y="${(y(s.compute + s.wait + s.over) - 8).toFixed(1)}" font-size="11.5" font-weight="600" fill="#111" text-anchor="middle">${(s.compute + s.wait + s.over).toFixed(2)} ms</text>`);
  svg.push(`<text x="${xc(i)}" y="${M.t + PH + 18}" font-size="12.5" fill="#111" text-anchor="middle">${LABEL[p]}</text>`);
});

const ly = H - 34;
const lx = M.l;
svg.push(`<rect x="${lx}" y="${ly - 9}" width="12" height="12" fill="${C_COMPUTE}"/>`);
svg.push(`<text x="${lx + 18}" y="${ly + 1}" font-size="11.5" fill="#333">in-app compute</text>`);
svg.push(`<rect x="${lx + 132}" y="${ly - 9}" width="12" height="12" fill="url(#hatch)" stroke="#33333322"/>`);
svg.push(`<text x="${lx + 150}" y="${ly + 1}" font-size="11.5" fill="#333">${MID_LABEL}</text>`);
svg.push(`<rect x="${lx + 246}" y="${ly - 9}" width="12" height="12" fill="${C_OVER}"/>`);
svg.push(`<text x="${lx + 264}" y="${ly + 1}" font-size="11.5" fill="#333">invocation + network (client - in-app)</text>`);
svg.push(`<text x="${M.l}" y="${H - 12}" font-size="10.5" fill="#666">medians across runs; whisker is the IQR of per-run mean total</text>`);
svg.push("</svg>");

// ---------------------------------------------------------------- pgfplots
const tex = [];
tex.push("% Generated by scripts/make-db-wait-figure.js. Do not edit.");
tex.push("% \\input{} into the SBC template; requires \\usepackage{pgfplots}.");
tex.push("\\begin{tikzpicture}");
tex.push("  \\begin{axis}[");
tex.push("      ybar stacked, bar width=22pt, width=0.86\\linewidth, height=6cm,");
tex.push(`      ymin=0, ymax=${yTop},`);
tex.push("      ylabel={mean time per request (ms)},");
tex.push(`      symbolic x coords={${present.map((p) => LABEL[p]).join(",")}},`);
tex.push("      xtick=data, ymajorgrids, major grid style={gray!25},");
tex.push("      legend style={at={(0.5,-0.18)}, anchor=north, legend columns=2, draw=none},");
tex.push("      legend cell align=left,");
tex.push("    ]");
tex.push(`    \\addplot+[fill=blue!70!black, draw=none] coordinates {${present.map((p) => `(${LABEL[p]},${stats[p].compute.toFixed(4)})`).join(" ")}};`);
tex.push(`    \\addplot+[fill=orange!80!black, draw=none, postaction={pattern=north east lines}] coordinates {${present.map((p) => `(${LABEL[p]},${stats[p].wait.toFixed(4)})`).join(" ")}};`);
  tex.push(`    \addplot+[fill=black!35, draw=none] coordinates {${present.map((p) => `(${LABEL[p]},${stats[p].over.toFixed(4)})`).join(" ")}};`);
tex.push("    \\legend{in-app compute, database wait, invocation + network}");
tex.push("  \\end{axis}");
tex.push("\\end{tikzpicture}");

const outDir = path.join(suiteDir, "figures");
fs.mkdirSync(outDir, { recursive: true });
const svgPath = path.join(outDir, `${suite}-latency-split.svg`);
const texPath = path.join(outDir, `${suite}-latency-split.tex`);
fs.writeFileSync(svgPath, svg.join("\n") + "\n");
fs.writeFileSync(texPath, tex.join("\n") + "\n");

console.log(`\n${suite} end-to-end latency split  (${condition}, ${nLabel})\n`);
const pad = (s, n) => String(s).padEnd(n);
console.log("  " + pad("platform", 10) + pad("compute", 11) + pad(MID_LABEL.slice(0,10), 11) + pad("overhead", 11) + pad("total", 12) + pad("IQR of total", 18) + "runs");
for (const p of present) {
  const s = stats[p];
  const iqr = s.q1 === null ? "-" : `[${s.q1.toFixed(2)}, ${s.q3.toFixed(2)}]`;
  console.log(
    "  " + pad(p, 10) + pad(s.compute.toFixed(2) + " ms", 11) + pad(s.wait.toFixed(2) + " ms", 11) + pad(s.over.toFixed(2) + " ms", 11) +
      pad(s.total.toFixed(2) + " ms", 12) + pad(iqr, 18) + s.n
  );
}
if (dropped.length) console.log(`\nexcluded for incomplete scrape coverage: ${dropped.join(", ")}`);
if (nRuns < 3) console.log(`\nnote: n=${nRuns}. IQR is undefined below n=2 and unstable below n=4.`);
console.log(`\nwrote ${svgPath}\n      ${texPath}`);
