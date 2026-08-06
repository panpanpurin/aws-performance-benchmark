#!/usr/bin/env bash
# Generates pilot-{ec2,ecs,lambda}.yml for each suite from the committed
# test-*.yml, replacing only the phases block with a short load below
# the saturation ceiling.
#
# One worker at 1 vCPU has a ceiling of roughly 1/mean_service_time. The pilot
# runs well below it so service time is measured uncontended; feed the result
# back into test-*.yml. See docs/PAPER-SSCAD-2026.md.
#
#   bash scripts/sync-artillery-targets.sh   # first: fills target + Host
#   bash scripts/make-pilot-configs.sh       # then: generates the pilots
#   bash benchmarks/scripts/run-parallel.sh csv-processor pilot
#
# Generated files are derived artefacts; regenerate rather than hand-editing.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

section "pilot configs"

# Node resolves paths relative to the process cwd, which Git Bash reports as a
# native Windows path. $ROOT is an MSYS path (/c/Users/...) that Node cannot
# resolve, so change directory here and keep the paths below relative.
cd "$ROOT"

node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = ".";

// Rates are a fraction of the ceiling so queueing never contributes. `ceiling`
// is the binding one, which is Lambda's on every suite, and is used only to
// state the pilot's utilisation in the generated comment.
//
// csv-processor's is measured (pilot 2026-08-04, from CloudWatch Duration);
// thumbnail-generator's is derived from it (2026-08-05, see its test-*.yml)
//
// reqsPerArrival: arrivalRate counts virtual users, not requests, and each runs
// the whole scenario. AniLove's flow is a five-step CRUD cycle; csv and
// thumbnail issue one request per arrival.
const suites = {
  "anilove": { warmRate: 1, rate: 1, measure: 300, ceiling: 22, reqsPerArrival: 5 },
  "csv-processor": { warmRate: 1, rate: 2, measure: 360, ceiling: 28, reqsPerArrival: 1 },
  "thumbnail-generator": { warmRate: 1, rate: 1, measure: 420, ceiling: 7, reqsPerArrival: 1 },
};

function phasesBlock(cfg) {
  const reqPerSec = cfg.rate * cfg.reqsPerArrival;
  const pct = ((reqPerSec / cfg.ceiling) * 100).toFixed(0);
  // arrivalCount, not arrivalRate. arrivalRate starts N virtual users at the same
  // instant each second, which a Lambda sandbox at concurrency 1 cannot absorb.
  // At 12 req/s: 234 HTTP 502s with arrivalRate, 3 with arrivalCount.
  const warmCount = cfg.warmRate * 60;
  const measureCount = cfg.rate * cfg.measure;
  return `  phases:
    # PILOT - not a measurement run. Purpose: obtain the real per-request
    # service time on each platform, uncontended, so the phases in test-*.yml
    # can be set relative to the actual saturation ceiling.
    #
    # Phase 1 - discard. Absorbs Lambda cold starts, JIT warm-up and connection
    # setup. Exclude this window when reading the result.
    - duration: 60
      arrivalCount: ${warmCount}

    # Phase 2 - measure. arrivalRate ${cfg.rate} x ${cfg.reqsPerArrival} request(s)
    # per arrival = ${reqPerSec} req/s, about ${pct}% of the estimated ceiling of
    # ~${cfg.ceiling} req/s for one 1-vCPU worker. Low enough that nothing queues,
    # so app_total_execution_time_seconds reflects service time rather than wait
    # time. Yields ~${reqPerSec * cfg.measure} timed requests.
    - duration: ${cfg.measure}
      arrivalCount: ${measureCount}
`;
}

let written = 0;
for (const [suite, cfg] of Object.entries(suites)) {
  let suiteWritten = 0;
  const dir = path.join(root, "benchmarks", "suites", suite, "artillery");
  for (const platform of ["ec2", "ecs", "lambda"]) {
    const src = path.join(dir, `test-${platform}.yml`);
    if (!fs.existsSync(src)) {
      console.log(`SKIP  ${suite}/test-${platform}.yml not found`);
      continue;
    }
    // Normalise to LF before matching. git converts these files to CRLF on
    // checkout on Windows, and the patterns below anchor on \n, so a fresh
    // clone would otherwise fail to locate the phases block in every suite.
    let text = fs.readFileSync(src, "utf8").replace(/\r\n/g, "\n");

    if (/REPLACE_ME/.test(text)) {
      console.log(`WARN  ${suite}/test-${platform}.yml still has REPLACE_ME - run sync-targets first`);
    }

    // The provisional-rates warning belongs to test-*.yml's own phases.
    text = text.replace(
      /^ {2}# -{10,}\n(?: {2}#[^\n]*\n)*? {2}# WARNING: these arrival rates are provisional\.[\s\S]*?^ {2}# -{10,}\n/m,
      ""
    );

    // Both are two-space-indented keys of `config:` in every suite.
    const re = /^ {2}phases:\n[\s\S]*?(?=^ {2}defaults:)/m;
    if (!re.test(text)) {
      console.log(`FAIL  ${suite}/test-${platform}.yml: could not locate phases block`);
      process.exitCode = 1;
      continue;
    }
    text = text.replace(re, phasesBlock(cfg) + "\n");

    // Distinguish pilot series in Prometheus; the instance label is untouched.
    text = text.replace(/^(\s*testName:\s*")([^"]*)(")/m, (m, a, name, c) =>
      name.endsWith("-pilot") ? m : `${a}${name}-pilot${c}`);

    const out = path.join(dir, `pilot-${platform}.yml`);
    fs.writeFileSync(
      out,
      `# GENERATED by scripts/make-pilot-configs.sh from test-${platform}.yml.\n` +
      `# Do not hand-edit; regenerate instead. Pilot run only - see the script\n` +
      `# header and docs/PAPER-SSCAD-2026.md for what to do with the result.\n` +
      text.replace(/^# [^\n]*\n/, "")
    );
    written++;
    suiteWritten++;
  }
  if (suiteWritten > 0) {
    console.log(`OK   ${suite}: ${suiteWritten} pilot(s) at ${cfg.rate} req/s for ${cfg.measure}s`);
  } else {
    console.log(`FAIL ${suite}: no pilots written`);
    process.exitCode = 1;
  }
}
console.log(`\n${written} pilot config(s) written.`);
NODE

cat <<'EOF'

Next:
  1. bash benchmarks/scripts/run-parallel.sh <suite> pilot
  2. In Prometheus, over the phase-2 window only, read mean service time:
       1000 * sum by (instance) (rate(app_total_execution_time_seconds_sum[2m]))
            / clamp_min(sum by (instance) (rate(app_total_execution_time_seconds_count[2m])), 1e-9)
  3. ceiling_req_s = 1000 / (slowest platform's mean ms)
     steady_req_s  = 0.65 * ceiling_req_s   <- the latency comparison's regime
     stress_req_s  = 1.2..1.5 * ceiling_req_s <- the only phase allowed above it
  4. Convert to arrivalRate before writing it into the YAML:
       arrivalRate = req_s / requests_per_arrival
     anilove issues 5 requests per arrival (the CRUD flow); csv-processor and
     thumbnail-generator issue 1. Skipping this step is how a schedule ends up
     five times over the ceiling while looking correct.
  5. Edit phases in test-*.yml, keeping all three platforms identical.
EOF
