// Capped versus uncapped, per platform: latency and error rate side by side.
//
//   node scripts/make-condition-figure.js anilove
//   make figure-condition-anilove
//
// Experiment B asks what the concurrency limit itself costs. Reads per-run.csv,
// written by aggregate-runs.js, so the windowing and the schedule check are done
// once in one place rather than reimplemented here. Run the aggregation first.
//
// Client-side only, deliberately. The app_* series are not valid under uncapped
// Lambda: several execution environments answer the scrape in turn, so the
// counters do not describe one container over the window. Artillery measures
// end to end from outside and is unaffected, which is why it is the only source
// that can compare the two conditions.
//
// EC2 and ECS are identical in both conditions, since only the Lambda variable
// changes. They are the control: if their bars differ, the two batches are not
// comparable and the Lambda contrast cannot be read.
//
// Two panels sharing an x-axis, never one plot with two y-scales: latency in ms
// and error rate in percent are different scales and would mislead overlaid.

const fs = require("fs");
const path = require("path");

const PLATFORMS = ["ec2", "ecs", "lambda"];
const LABEL = { ec2: "EC2", ecs: "ECS", lambda: "Lambda" };
const CONDITIONS = ["capped", "uncapped"];
// One hue per condition, distinguishable in grayscale by the hatch on uncapped.
const COLOR = { capped: "#2a78d6", uncapped: "#eb6834" };

function usage(msg) {
  if (msg) console.error("error: " + msg + "\n");
  console.error("usage: node scripts/make-condition-figure.js <suite> [--logs DIR]\n");
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
const csvPath = path.join(logsDir, "per-run.csv");
if (!fs.existsSync(csvPath)) usage(`no per-run.csv in ${logsDir}. Run make aggregate-${suite.split("-")[0]} first.`);

const median = (a) => {
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const quartiles = (a) => {
  if (a.length < 2) return [null, null];
  const s = [...a].sort((x, y) => x - y);
  const h = s.length >> 1;
  return [median(s.slice(0, h)), median(s.slice(s.length % 2 ? h + 1 : h))];
};

const lines = fs.readFileSync(csvPath, "utf8").trim().split(/\r?\n/);
const head = lines[0].split(",");
const col = (n) => head.indexOf(n);
const rows = lines.slice(1).map((l) => l.split(","));

const stats = {};
for (const p of PLATFORMS) {
  for (const c of CONDITIONS) {
    const sel = rows.filter((r) => r[col("platform")] === p && r[col("condition")] === c);
    if (!sel.length) continue;
    const mean = sel.map((r) => Number(r[col("mean_ms")])).filter(Number.isFinite);
    const err = sel.map((r) => Number(r[col("error_rate_pct")])).filter(Number.isFinite);
    const [q1, q3] = quartiles(mean);
    stats[p + "|" + c] = { n: sel.length, mean: median(mean), q1, q3, err: median(err) };
  }
}
const present = PLATFORMS.filter((p) => CONDITIONS.some((c) => stats[p + "|" + c]));
if (!present.length) {
  console.error("no rows for either condition in per-run.csv");
  process.exit(1);
}
const haveBoth = present.filter((p) => stats[p + "|capped"] && stats[p + "|uncapped"]);
if (!haveBoth.length) {
  console.error("only one condition present; nothing to compare. Run the other condition first.");
  process.exit(1);
}

const latTop = Math.ceil((Math.max(...present.flatMap((p) => CONDITIONS.map((c) => (stats[p + "|" + c] ? stats[p + "|" + c].q3 || stats[p + "|" + c].mean : 0)))) * 1.2) / 5) * 5;
const errMax = Math.max(...present.flatMap((p) => CONDITIONS.map((c) => (stats[p + "|" + c] ? stats[p + "|" + c].err : 0))));
const errTop = Math.max(0.2, Math.ceil((errMax * 1.3) * 100) / 100);

// ---------------------------------------------------------------- SVG
const W = 660;
const H = 470;
const M = { l: 62, r: 18, t: 34, b: 96 };
const PW = W - M.l - M.r;
const PA = { y: 44, h: 210 };
const PB = { y: 296, h: 92 };
const groupW = PW / present.length;
const bw = Math.min(46, groupW / 3.2);

const yA = (v) => PA.y + PA.h - (v / latTop) * PA.h;
const yB = (v) => PB.y + PB.h - (v / errTop) * PB.h;
const xc = (i) => M.l + groupW * (i + 0.5);
const xb = (i, k) => xc(i) - bw - 4 + k * (bw + 8);

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");
const svg = [];
svg.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="Helvetica, Arial, sans-serif">`);
svg.push(`<defs><pattern id="up" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">` +
  `<rect width="6" height="6" fill="${COLOR.uncapped}"/><line x1="0" y1="0" x2="0" y2="6" stroke="#fff" stroke-width="2" opacity="0.55"/></pattern></defs>`);
svg.push(`<rect width="${W}" height="${H}" fill="#ffffff"/>`);
const nCap = stats["ec2|capped"] ? stats["ec2|capped"].n : 0;
const nUnc = stats["ec2|uncapped"] ? stats["ec2|uncapped"].n : 0;
svg.push(`<text x="${M.l}" y="20" font-size="13" font-weight="600" fill="#111">${esc(suite)}: reserved concurrency 1 vs uncapped (n=${nCap} vs ${nUnc})</text>`);

const fill = (c) => (c === "capped" ? COLOR.capped : "url(#up)");

// Panel A, latency
for (let v = 0; v <= latTop + 1e-9; v += 5) {
  svg.push(`<line x1="${M.l}" y1="${yA(v).toFixed(1)}" x2="${M.l + PW}" y2="${yA(v).toFixed(1)}" stroke="#e6e6e6"/>`);
  svg.push(`<text x="${M.l - 8}" y="${(yA(v) + 4).toFixed(1)}" font-size="11" fill="#555" text-anchor="end">${v}</text>`);
}
svg.push(`<text x="15" y="${PA.y + PA.h / 2}" font-size="12" fill="#333" text-anchor="middle" transform="rotate(-90 15 ${PA.y + PA.h / 2})">mean latency (ms)</text>`);
svg.push(`<line x1="${M.l}" y1="${PA.y + PA.h}" x2="${M.l + PW}" y2="${PA.y + PA.h}" stroke="#888"/>`);
present.forEach((p, i) => {
  CONDITIONS.forEach((c, k) => {
    const s = stats[p + "|" + c];
    if (!s) return;
    const x = xb(i, k);
    svg.push(`<rect x="${x.toFixed(1)}" y="${yA(s.mean).toFixed(1)}" width="${bw.toFixed(1)}" height="${(PA.y + PA.h - yA(s.mean)).toFixed(1)}" fill="${fill(c)}" stroke="#33333322"/>`);
    if (s.q1 !== null && s.q3 !== null && s.q3 > s.q1) {
      const cx = x + bw / 2;
      svg.push(`<line x1="${cx}" y1="${yA(s.q1).toFixed(1)}" x2="${cx}" y2="${yA(s.q3).toFixed(1)}" stroke="#222" stroke-width="1.3"/>`);
      for (const q of [s.q1, s.q3]) svg.push(`<line x1="${cx - 6}" y1="${yA(q).toFixed(1)}" x2="${cx + 6}" y2="${yA(q).toFixed(1)}" stroke="#222" stroke-width="1.3"/>`);
    }
    svg.push(`<text x="${(x + bw / 2).toFixed(1)}" y="${(yA(s.mean) - 6).toFixed(1)}" font-size="10.5" fill="#111" text-anchor="middle">${s.mean.toFixed(1)}</text>`);
  });
});

// Panel B, error rate
svg.push(`<text x="${M.l}" y="${PB.y - 10}" font-size="11.5" font-weight="600" fill="#333">non-2xx responses (%)</text>`);
for (const v of [0, errTop]) {
  svg.push(`<line x1="${M.l}" y1="${yB(v).toFixed(1)}" x2="${M.l + PW}" y2="${yB(v).toFixed(1)}" stroke="#e6e6e6"/>`);
  svg.push(`<text x="${M.l - 8}" y="${(yB(v) + 4).toFixed(1)}" font-size="11" fill="#555" text-anchor="end">${v.toFixed(2)}</text>`);
}
svg.push(`<line x1="${M.l}" y1="${PB.y + PB.h}" x2="${M.l + PW}" y2="${PB.y + PB.h}" stroke="#888"/>`);
present.forEach((p, i) => {
  CONDITIONS.forEach((c, k) => {
    const s = stats[p + "|" + c];
    if (!s) return;
    const x = xb(i, k);
    const h = Math.max(s.err > 0 ? 1.5 : 0, PB.y + PB.h - yB(s.err));
    svg.push(`<rect x="${x.toFixed(1)}" y="${(PB.y + PB.h - h).toFixed(1)}" width="${bw.toFixed(1)}" height="${h.toFixed(1)}" fill="${fill(c)}" stroke="#33333322"/>`);
    svg.push(`<text x="${(x + bw / 2).toFixed(1)}" y="${(PB.y + PB.h - h - 5).toFixed(1)}" font-size="10" fill="#111" text-anchor="middle">${s.err.toFixed(2)}</text>`);
  });
  svg.push(`<text x="${xc(i)}" y="${PB.y + PB.h + 20}" font-size="12.5" fill="#111" text-anchor="middle">${LABEL[p]}</text>`);
});

const ly = H - 30;
svg.push(`<rect x="${M.l}" y="${ly - 9}" width="12" height="12" fill="${COLOR.capped}"/>`);
svg.push(`<text x="${M.l + 18}" y="${ly + 1}" font-size="11.5" fill="#333">reserved concurrency 1</text>`);
svg.push(`<rect x="${M.l + 170}" y="${ly - 9}" width="12" height="12" fill="url(#up)" stroke="#33333322"/>`);
svg.push(`<text x="${M.l + 188}" y="${ly + 1}" font-size="11.5" fill="#333">uncapped</text>`);
svg.push(`<text x="${M.l}" y="${H - 10}" font-size="10.5" fill="#666">medians across runs; whiskers are the IQR of per-run mean latency</text>`);
svg.push("</svg>");

// ---------------------------------------------------------------- pgfplots
const tex = [];
tex.push("% Generated by scripts/make-condition-figure.js. Do not edit.");
tex.push("\\begin{tikzpicture}");
tex.push("  \\begin{axis}[");
tex.push("      ybar, bar width=10pt, width=0.86\\linewidth, height=6cm,");
tex.push(`      ymin=0, ymax=${latTop}, ylabel={mean latency (ms)},`);
tex.push(`      symbolic x coords={${present.map((p) => LABEL[p]).join(",")}},`);
tex.push("      xtick=data, ymajorgrids, major grid style={gray!25},");
tex.push("      legend style={at={(0.5,-0.16)}, anchor=north, legend columns=2, draw=none},");
tex.push("      legend cell align=left,");
tex.push("    ]");
for (const c of CONDITIONS) {
  const pts = present.filter((p) => stats[p + "|" + c]).map((p) => `(${LABEL[p]},${stats[p + "|" + c].mean.toFixed(3)})`);
  if (!pts.length) continue;
  const style = c === "capped" ? "fill=blue!70!black, draw=none" : "fill=orange!80!black, draw=none, postaction={pattern=north east lines}";
  tex.push(`    \\addplot+[${style}] coordinates {${pts.join(" ")}};`);
}
tex.push(`    \\legend{reserved concurrency 1, uncapped}`);
tex.push("  \\end{axis}");
tex.push("\\end{tikzpicture}");

const outDir = path.join(suiteDir, "figures");
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, `${suite}-condition.svg`), svg.join("\n") + "\n");
fs.writeFileSync(path.join(outDir, `${suite}-condition.tex`), tex.join("\n") + "\n");

console.log(`\n${suite}: capped vs uncapped\n`);
const pad = (s, n) => String(s).padEnd(n);
console.log("  " + pad("platform", 10) + pad("condition", 11) + pad("n", 4) + pad("mean ms", 22) + "err %");
for (const p of present) {
  for (const c of CONDITIONS) {
    const s = stats[p + "|" + c];
    if (!s) continue;
    const iqr = s.q1 === null ? "" : ` [${s.q1.toFixed(2)}, ${s.q3.toFixed(2)}]`;
    console.log("  " + pad(p, 10) + pad(c, 11) + pad(s.n, 4) + pad(s.mean.toFixed(2) + iqr, 22) + s.err.toFixed(3));
  }
}
console.log(`\nwrote ${path.join(outDir, suite + "-condition.svg")}\n      ${path.join(outDir, suite + "-condition.tex")}`);
