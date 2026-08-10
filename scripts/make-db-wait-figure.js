// Stacked decomposition of mean service time into compute and database wait.
//
//   node scripts/make-db-wait-figure.js anilove
//   make figure-dbwait-anilove
//
// Reads every app-metrics-<run-id>.json written by capture-app-metrics.js and
// plots, per platform, the median across runs of mean compute time and mean
// database wait. This is the AniLove-specific figure: csv-processor and
// thumbnail-generator have no database, so the split does not exist for them.
//
// Means, not percentiles. Percentiles do not subtract, so the wait can only be
// obtained as mean(total) - mean(internal). The bar height is therefore the sum
// of two medians, which is not identical to the median total; the whisker gives
// the IQR of the per-run total so the spread is still visible. Say so in the
// caption.
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

const runs = [];
for (const f of files) {
  const j = JSON.parse(fs.readFileSync(path.join(logsDir, f), "utf8"));
  if (condition !== "all" && j.condition !== condition) continue;
  runs.push(j);
}
if (!runs.length) {
  console.error(`no ${condition} runs among ${files.length} capture(s). Try --condition all.`);
  process.exit(1);
}

// A run-platform below this covers only part of its window and is excluded.
const MIN_COVERAGE = Number(flag("min-coverage", 0.9));
const dropped = [];
const stats = {};
for (const p of PLATFORMS) {
  const comp = [];
  const wait = [];
  const total = [];
  for (const r of runs) {
    const v = r.platforms[p];
    if (!v || v.internal_ms === null) continue;
    // Partial windows are not comparable with whole ones. Written by
    // capture-app-metrics.js; usually a Lambda environment recycled mid-run.
    if (v.scrape_coverage !== null && v.scrape_coverage !== undefined && v.scrape_coverage < MIN_COVERAGE) {
      dropped.push(`${r.run_id} ${p} ${(100 * v.scrape_coverage).toFixed(0)}%`);
      continue;
    }
    comp.push(v.internal_ms);
    wait.push(v.db_wait_ms);
    total.push(v.total_ms);
  }
  if (!comp.length) continue;
  const [q1, q3] = quartiles(total);
  stats[p] = { n: comp.length, compute: median(comp), wait: median(wait), total: median(total), q1, q3 };
}
const present = PLATFORMS.filter((p) => stats[p]);
if (!present.length) {
  console.error("no platform has an internal-time series. This figure only applies to anilove.");
  process.exit(1);
}

const nRuns = Math.max(...present.map((p) => stats[p].n));
const top = Math.max(...present.map((p) => Math.max(stats[p].compute + stats[p].wait, stats[p].q3 || 0)));
const yTop = Math.ceil((top * 1.18) / 0.5) * 0.5;

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
svg.push(`<text x="${M.l}" y="20" font-size="13" font-weight="600" fill="#111">Mean service time split, ${esc(suite)} (${esc(condition)}, n=${nRuns})</text>`);

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
  svg.push(`<rect x="${x.toFixed(1)}" y="${y(s.compute).toFixed(1)}" width="${bw.toFixed(1)}" height="${hC.toFixed(1)}" fill="${C_COMPUTE}"/>`);
  svg.push(`<rect x="${x.toFixed(1)}" y="${y(s.compute + s.wait).toFixed(1)}" width="${bw.toFixed(1)}" height="${hW.toFixed(1)}" fill="url(#hatch)"/>`);
  svg.push(`<rect x="${x.toFixed(1)}" y="${y(s.compute + s.wait).toFixed(1)}" width="${bw.toFixed(1)}" height="${(hC + hW).toFixed(1)}" fill="none" stroke="#33333322"/>`);
  if (s.q1 !== null && s.q3 !== null && s.q3 > s.q1) {
    const cx = xc(i);
    svg.push(`<line x1="${cx}" y1="${y(s.q1).toFixed(1)}" x2="${cx}" y2="${y(s.q3).toFixed(1)}" stroke="#222" stroke-width="1.4"/>`);
    for (const q of [s.q1, s.q3])
      svg.push(`<line x1="${cx - 9}" y1="${y(q).toFixed(1)}" x2="${cx + 9}" y2="${y(q).toFixed(1)}" stroke="#222" stroke-width="1.4"/>`);
  }
  svg.push(`<text x="${xc(i)}" y="${(y(s.compute + s.wait) - 8).toFixed(1)}" font-size="11.5" font-weight="600" fill="#111" text-anchor="middle">${(s.compute + s.wait).toFixed(2)} ms</text>`);
  svg.push(`<text x="${xc(i)}" y="${M.t + PH + 18}" font-size="12.5" fill="#111" text-anchor="middle">${LABEL[p]}</text>`);
});

const ly = H - 34;
const lx = M.l;
svg.push(`<rect x="${lx}" y="${ly - 9}" width="12" height="12" fill="${C_COMPUTE}"/>`);
svg.push(`<text x="${lx + 18}" y="${ly + 1}" font-size="11.5" fill="#333">in-app compute</text>`);
svg.push(`<rect x="${lx + 132}" y="${ly - 9}" width="12" height="12" fill="url(#hatch)" stroke="#33333322"/>`);
svg.push(`<text x="${lx + 150}" y="${ly + 1}" font-size="11.5" fill="#333">database wait (total - internal)</text>`);
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
tex.push("    \\legend{in-app compute, database wait}");
tex.push("  \\end{axis}");
tex.push("\\end{tikzpicture}");

const outDir = path.join(suiteDir, "figures");
fs.mkdirSync(outDir, { recursive: true });
const svgPath = path.join(outDir, `${suite}-db-wait.svg`);
const texPath = path.join(outDir, `${suite}-db-wait.tex`);
fs.writeFileSync(svgPath, svg.join("\n") + "\n");
fs.writeFileSync(texPath, tex.join("\n") + "\n");

console.log(`\n${suite} database-wait split  (${condition}, n=${nRuns})\n`);
const pad = (s, n) => String(s).padEnd(n);
console.log("  " + pad("platform", 10) + pad("compute", 12) + pad("db wait", 12) + pad("total", 12) + "IQR of total");
for (const p of present) {
  const s = stats[p];
  const iqr = s.q1 === null ? "-" : `[${s.q1.toFixed(2)}, ${s.q3.toFixed(2)}]`;
  console.log(
    "  " + pad(p, 10) + pad(s.compute.toFixed(2) + " ms", 12) + pad(s.wait.toFixed(2) + " ms", 12) +
      pad(s.total.toFixed(2) + " ms", 12) + iqr
  );
}
if (dropped.length) console.log(`\nexcluded for incomplete scrape coverage: ${dropped.join(", ")}`);
if (nRuns < 3) console.log(`\nnote: n=${nRuns}. IQR is undefined below n=2 and unstable below n=4.`);
console.log(`\nwrote ${svgPath}\n      ${texPath}`);
