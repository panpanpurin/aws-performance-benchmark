// Build the phase-series figure for a suite from one representative run.
//
//   node scripts/make-figures.js csv-processor 20260804-144650
//   make figure-csv
//
// Emits benchmarks/suites/<suite>/figures/<suite>-phases.{svg,tex}. The .tex is
// pgfplots for \input{} into the SBC template; the .svg is for Word or a browser.
//
// One run, not an average across runs: the figure exists to show the phase steps
// and averaging repetitions smears the boundaries into slopes. See
// docs/PAPER-SSCAD-2026.md "How many repetitions".
//
// Latency and error rate are separate stacked panels sharing an x-axis, never one
// plot with two y-scales. Two measures of different scale need two panels.

const fs = require("fs");
const path = require("path");

const PLATFORMS = ["ec2", "ecs", "lambda"];
const LABEL = { ec2: "EC2", ecs: "ECS", lambda: "Lambda" };
// Categorical slots 1-3 of the validated palette. These three clear the
// all-pairs CVD and normal-vision floors in both modes.
const COLOR = { ec2: "#2a78d6", ecs: "#eb6834", lambda: "#1baf7a" };
// Secondary encoding so the figure survives a grayscale print.
const DASH = { ec2: "", ecs: "7 4", lambda: "2 3" };
const PGF_DASH = { ec2: "solid", ecs: "dashed", lambda: "dotted" };

const [suite, runId] = process.argv.slice(2);
if (!suite || !runId) {
  console.error("usage: node scripts/make-figures.js <suite> <run-id>");
  process.exit(1);
}

const suiteDir = path.join("benchmarks", "suites", suite);
const logsDir = path.join(suiteDir, "artillery", "logs");

function readPhases() {
  const text = fs.readFileSync(path.join(suiteDir, "artillery", "test-ec2.yml"), "utf8");
  const phases = [];
  const re = /^\s*-\s*duration:\s*(\d+)\s*$/gm;
  let m;
  while ((m = re.exec(text)) !== null) {
    const rest = text.slice(m.index + m[0].length, m.index + m[0].length + 200);
    const c = /arrivalCount:\s*(\d+)/.exec(rest);
    const duration = Number(m[1]);
    phases.push({ duration, rate: c ? Math.round(Number(c[1]) / duration) : null });
  }
  let t = 0;
  for (const p of phases) {
    p.start = t;
    p.end = t + p.duration;
    t = p.end;
  }
  return phases;
}

const phases = readPhases();
const totalS = phases[phases.length - 1].end;

function readSeries(platform) {
  const candidates = [`loadgen-test-${platform}-${runId}.json`, `test-${platform}-${runId}.json`];
  const file = candidates.map((f) => path.join(logsDir, f)).find((f) => fs.existsSync(f));
  if (!file) return null;
  const im = JSON.parse(fs.readFileSync(file, "utf8")).intermediate || [];
  if (!im.length) return null;
  const t0 = Number(im[0].period);

  const points = [];
  const byPhase = phases.map(() => ({ req: 0, bad: 0 }));
  for (const p of im) {
    const el = (Number(p.period) - t0) / 1000;
    const s = (p.summaries || {})["http.response_time"];
    if (s) points.push([el, s.p50]);
    const i = phases.findIndex((ph) => el >= ph.start && el < ph.end);
    if (i < 0) continue;
    for (const [k, v] of Object.entries(p.counters || {})) {
      if (k === "http.requests") byPhase[i].req += v;
      else if (k.startsWith("http.codes.") && !k.slice(11).startsWith("2")) byPhase[i].bad += v;
    }
  }
  return {
    points,
    errPct: byPhase.map((x) => (x.req ? (100 * x.bad) / x.req : 0)),
    // Observed request rate, not arrivalCount/duration. AniLove's scenario is a
    // five-step CRUD flow, so one arrival is five requests and the YAML rate would
    // understate the axis label by 5x. Reading it back from the report is correct
    // for any suite regardless of flow shape.
    reqPerS: byPhase.map((x, i) => x.req / phases[i].duration),
  };
}

const data = {};
for (const p of PLATFORMS) {
  const s = readSeries(p);
  if (s) data[p] = s;
}
const present = PLATFORMS.filter((p) => data[p]);
if (!present.length) {
  console.error(`no reports for run ${runId} in ${logsDir}`);
  process.exit(1);
}

// Rates come from the run itself; the YAML value is only a fallback for a suite
// whose report is missing counters.
const ref = data[present[0]];
phases.forEach((ph, i) => {
  const observed = ref.reqPerS[i];
  ph.label = observed > 0 ? (observed >= 10 ? Math.round(observed) : +observed.toFixed(1)) : ph.rate;
});

const maxLat = Math.max(...present.flatMap((p) => data[p].points.map((q) => q[1])));
const maxErr = Math.max(...present.flatMap((p) => data[p].errPct));
const latTop = Math.ceil(maxLat / 20) * 20;
const errTop = Math.max(2, Math.ceil(maxErr / 2) * 2);

// ---------------------------------------------------------------- SVG
const W = 920;
// Bottom margin carries three stacked rows: tick labels, axis title, legend.
const M = { l: 62, r: 104, t: 46, b: 78 };
const PA = { y: 46, h: 250 }; // latency panel
const PB = { y: 356, h: 108 }; // error panel
const H = PB.y + PB.h + M.b;
const plotW = W - M.l - M.r;
const x = (s) => M.l + (s / totalS) * plotW;
const yA = (v) => PA.y + PA.h - (v / latTop) * PA.h;
const yB = (v) => PB.y + PB.h - (v / errTop) * PB.h;

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");
const svg = [];
svg.push(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" font-family="Inter, Helvetica, Arial, sans-serif">`);
svg.push(`<rect width="${W}" height="${H}" fill="#fcfcfb"/>`);

// Phase bands and their arrival rates. The reader needs the operating point to
// interpret anything else in the figure.
phases.forEach((ph, i) => {
  if (i % 2 === 1) {
    svg.push(`<rect x="${x(ph.start).toFixed(1)}" y="${PA.y}" width="${(x(ph.end) - x(ph.start)).toFixed(1)}" height="${PA.h}" fill="#000" opacity="0.028"/>`);
    svg.push(`<rect x="${x(ph.start).toFixed(1)}" y="${PB.y}" width="${(x(ph.end) - x(ph.start)).toFixed(1)}" height="${PB.h}" fill="#000" opacity="0.028"/>`);
  }
  const mid = (x(ph.start) + x(ph.end)) / 2;
  svg.push(`<text x="${mid.toFixed(1)}" y="${PA.y - 18}" text-anchor="middle" font-size="12" fill="#52514e">${ph.label} req/s</text>`);
});
svg.push(`<text x="${M.l}" y="${PA.y - 32}" font-size="11" fill="#8a8880">phase</text>`);

// Recessive gridlines, labelled on the left.
for (let v = 0; v <= latTop; v += 20) {
  svg.push(`<line x1="${M.l}" x2="${W - M.r}" y1="${yA(v).toFixed(1)}" y2="${yA(v).toFixed(1)}" stroke="#000" stroke-opacity="0.08"/>`);
  svg.push(`<text x="${M.l - 10}" y="${(yA(v) + 4).toFixed(1)}" text-anchor="end" font-size="11" fill="#52514e">${v}</text>`);
}
for (let v = 0; v <= errTop; v += errTop / 2) {
  svg.push(`<line x1="${M.l}" x2="${W - M.r}" y1="${yB(v).toFixed(1)}" y2="${yB(v).toFixed(1)}" stroke="#000" stroke-opacity="0.08"/>`);
  svg.push(`<text x="${M.l - 10}" y="${(yB(v) + 4).toFixed(1)}" text-anchor="end" font-size="11" fill="#52514e">${v}</text>`);
}

svg.push(`<text x="${M.l - 46}" y="${PA.y + PA.h / 2}" font-size="12" fill="#0b0b0b" transform="rotate(-90 ${M.l - 46} ${PA.y + PA.h / 2})" text-anchor="middle">median latency (ms)</text>`);
svg.push(`<text x="${M.l - 46}" y="${PB.y + PB.h / 2}" font-size="12" fill="#0b0b0b" transform="rotate(-90 ${M.l - 46} ${PB.y + PB.h / 2})" text-anchor="middle">failed (%)</text>`);

// x ticks every 300 s
for (let s = 0; s <= totalS; s += 300) {
  svg.push(`<text x="${x(s).toFixed(1)}" y="${PB.y + PB.h + 18}" text-anchor="middle" font-size="11" fill="#52514e">${s}</text>`);
}
svg.push(`<text x="${(M.l + plotW / 2).toFixed(1)}" y="${PB.y + PB.h + 38}" text-anchor="middle" font-size="12" fill="#0b0b0b">elapsed (s)</text>`);

// Latency lines, then a direct label at each line's right end.
for (const p of present) {
  const d = data[p].points.map(([s, v], i) => `${i ? "L" : "M"}${x(s).toFixed(1)},${yA(v).toFixed(1)}`).join("");
  svg.push(`<path d="${d}" fill="none" stroke="${COLOR[p]}" stroke-width="2" stroke-linejoin="round"${DASH[p] ? ` stroke-dasharray="${DASH[p]}"` : ""}/>`);
}
// Step series for error rate, one flat segment per phase.
for (const p of present) {
  const seg = [];
  phases.forEach((ph, i) => {
    const v = data[p].errPct[i];
    seg.push(`${i ? "L" : "M"}${x(ph.start).toFixed(1)},${yB(v).toFixed(1)}L${x(ph.end).toFixed(1)},${yB(v).toFixed(1)}`);
  });
  svg.push(`<path d="${seg.join("")}" fill="none" stroke="${COLOR[p]}" stroke-width="2" stroke-linejoin="round"${DASH[p] ? ` stroke-dasharray="${DASH[p]}"` : ""}/>`);
}

// Direct labels beat a legend lookup, and satisfy the relief rule for the aqua
// slot, which sits below 3:1 on this surface.
// Each label starts at its own line's height, then a single downward pass opens
// only the pairs that actually overlap. Anchoring to the line is the whole point,
// so nothing moves unless it has to.
const GAP = 15;
// Median of the tail, not the final point: one noisy 10 s period should not decide
// where a label sits, and adjacent series often tie on a single reading.
const tailY = (p) => {
  const tail = data[p].points.slice(-6).map((q) => q[1]).sort((a, b) => a - b);
  return yA(tail[Math.floor(tail.length / 2)]) + 4;
};
const ends = present.map((p) => ({ p, y: tailY(p) })).sort((a, b) => a.y - b.y);
for (let i = 1; i < ends.length; i++) {
  if (ends[i].y - ends[i - 1].y < GAP) ends[i].y = ends[i - 1].y + GAP;
}
for (const e of ends) {
  svg.push(`<text x="${W - M.r + 10}" y="${e.y.toFixed(1)}" font-size="12" fill="#0b0b0b">${LABEL[e.p]}</text>`);
}
// Peak annotation: the knee is the finding, so it is called out rather than left
// for the reader to spot.
const worst = present.map((p) => ({ p, v: data[p].errPct[phases.length - 1] })).sort((a, b) => b.v - a.v)[0];
if (worst.v > 1) {
  const px = x((phases[phases.length - 1].start + phases[phases.length - 1].end) / 2);
  svg.push(`<text x="${(px + 8).toFixed(1)}" y="${(yB(worst.v) + 14).toFixed(1)}" font-size="12" fill="#0b0b0b">${LABEL[worst.p]} ${worst.v.toFixed(1)}%</text>`);
}

// Legend row: identity is never carried by color alone.
const legY = PB.y + PB.h + 62;
let lx = M.l;
svg.push(`<g>`);
for (const p of present) {
  svg.push(`<line x1="${lx}" x2="${lx + 22}" y1="${legY}" y2="${legY}" stroke="${COLOR[p]}" stroke-width="2"${DASH[p] ? ` stroke-dasharray="${DASH[p]}"` : ""}/>`);
  svg.push(`<text x="${lx + 28}" y="${legY + 4}" font-size="12" fill="#52514e">${LABEL[p]}</text>`);
  lx += 28 + LABEL[p].length * 7 + 22;
}
svg.push(`</g></svg>`);

const outDir = path.join(suiteDir, "figures");
fs.mkdirSync(outDir, { recursive: true });
const svgPath = path.join(outDir, `${suite}-phases.svg`);
fs.writeFileSync(svgPath, svg.join("\n") + "\n");

// ---------------------------------------------------------------- pgfplots
const tex = [];
tex.push(`% Generated by scripts/make-figures.js from run ${runId}. Do not edit by hand.`);
tex.push(`% Requires \\usepackage{pgfplots} and \\pgfplotsset{compat=1.18} in the preamble.`);
tex.push(`\\begin{figure}[t]\\centering`);
tex.push(`\\begin{tikzpicture}`);
tex.push(`\\begin{groupplot}[group style={group size=1 by 2, vertical sep=0.9cm},`);
tex.push(`  width=\\linewidth, xmin=0, xmax=${totalS}, tick align=outside, grid=major,`);
tex.push(`  grid style={black!10}, every axis plot/.append style={line width=1pt}]`);

tex.push(`\\nextgroupplot[height=5.2cm, ylabel={median latency (ms)}, ymin=0, ymax=${latTop},`);
tex.push(`  xticklabels={}, legend style={draw=none, fill=none, font=\\small},`);
tex.push(`  legend columns=${present.length}, legend to name=csvphaseslegend]`);
for (const p of present) {
  const coords = data[p].points.map(([s, v]) => `(${s},${v})`).join(" ");
  tex.push(`\\addplot[color=${p}color, ${PGF_DASH[p]}] coordinates {${coords}};`);
  tex.push(`\\addlegendentry{${LABEL[p]}}`);
}
tex.push(`\\nextgroupplot[height=3.0cm, ylabel={failed (\\%)}, xlabel={elapsed (s)}, ymin=0, ymax=${errTop}]`);
for (const p of present) {
  const coords = phases.map((ph, i) => `(${ph.start},${data[p].errPct[i].toFixed(2)}) (${ph.end},${data[p].errPct[i].toFixed(2)})`).join(" ");
  tex.push(`\\addplot[color=${p}color, ${PGF_DASH[p]}] coordinates {${coords}};`);
}
tex.push(`\\end{groupplot}`);
tex.push(`\\node at ($(group c1r1.north)+(0,0.6cm)$) {\\pgfplotslegendfromname{csvphaseslegend}};`);
tex.push(`\\end{tikzpicture}`);
const rates = phases.map((p) => `${p.label}`).join(", ");
tex.push(`\\caption{Median latency and failure rate across the ${phases.length} load phases (${rates} req/s) for one representative run (\\texttt{${runId}}). A single run is shown because averaging repetitions smears the phase boundaries.}`);
tex.push(`\\label{fig:${suite}-phases}`);
tex.push(`\\end{figure}`);

// Colour definitions go in the preamble, emitted alongside so the file is usable
// without hunting for the hex values.
const preamble = present.map((p) => `\\definecolor{${p}color}{HTML}{${COLOR[p].slice(1).toUpperCase()}}`).join("\n");
const texPath = path.join(outDir, `${suite}-phases.tex`);
fs.writeFileSync(texPath, `% Preamble, once per document:\n% \\usepackage{pgfplots}\n% \\usetikzlibrary{calc}\n% \\pgfplotsset{compat=1.18}\n${preamble.replace(/^/gm, "% ")}\n\n${tex.join("\n")}\n`);

console.log(`run       ${runId}`);
console.log(`platforms ${present.join(", ")}`);
console.log(`phases    ${phases.map((p) => `${p.rate}/s x ${p.duration}s`).join("  ")}`);
console.log(`latency   max ${maxLat} ms, axis to ${latTop}`);
console.log(`failures  max ${maxErr.toFixed(2)}%, axis to ${errTop}`);
console.log(`wrote     ${svgPath}`);
console.log(`wrote     ${texPath}`);
