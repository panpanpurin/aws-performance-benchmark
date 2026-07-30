#!/usr/bin/env bash
# Write Artillery targets from terraform/generated/benchmark-targets.json
#
#   ./scripts/sync-artillery-targets.sh
#   make sync-targets

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_targets
need node

cd "$ROOT"
# Pass paths Node understands on Windows Git Bash
if command -v cygpath >/dev/null 2>&1; then
  ROOT_NODE="$(cygpath -m "$ROOT")"
  TARGETS_NODE="$(cygpath -m "$TARGETS_FILE")"
else
  ROOT_NODE="$ROOT"
  TARGETS_NODE="$TARGETS_FILE"
fi

node - "$ROOT_NODE" "$TARGETS_NODE" <<'NODE'
const fs = require("fs");
const path = require("path");

const root = process.argv[2];
const targetsPath = process.argv[3];
const targets = JSON.parse(fs.readFileSync(targetsPath, "utf8"));
const albDns = targets.alb_dns;
if (!albDns) {
  console.error("ERROR: alb_dns missing in", targetsPath);
  process.exit(1);
}
const albUrl = `http://${albDns}`;
const hosts = targets.hostnames || {};
const lambdas = targets.lambda_urls || {};

function stripSlash(u) {
  return (u || "").replace(/\/$/, "");
}

function setTarget(text, url) {
  return text.replace(/^(\s*target:\s*)(["']).*\2/m, `$1"${url}"`);
}

function setHost(text, host) {
  if (/^\s*Host:\s*/m.test(text)) {
    return text.replace(/^(\s*Host:\s*).*$/m, `$1${host}`);
  }
  if (/^\s*headers:\s*$/m.test(text)) {
    return text.replace(/^(\s*)headers:\s*$/m, `$1headers:\n$1  Host: ${host}`);
  }
  if (/^\s*defaults:\s*$/m.test(text)) {
    return text.replace(
      /^(\s*)defaults:\s*$/m,
      `$1defaults:\n$1  headers:\n$1    Host: ${host}`
    );
  }
  return text;
}

function setComment(text, comment) {
  const lines = text.split(/\r?\n/);
  if (lines[0] && lines[0].startsWith("#")) lines[0] = comment;
  else lines.unshift(comment);
  return lines.join("\n");
}

const apps = {
  anilove: {
    dir: "benchmarks/suites/anilove/artillery",
    ec2: hosts.anilove_ec2 || "anilove-ec2.bench.local",
    ecs: hosts.anilove_ecs || "anilove-ecs.bench.local",
    lambda: stripSlash(lambdas.anilove),
  },
  "csv-processor": {
    dir: "benchmarks/suites/csv-processor/artillery",
    ec2: hosts.csv_ec2 || "csv-processor-ec2.bench.local",
    ecs: hosts.csv_ecs || "csv-processor-ecs.bench.local",
    lambda: stripSlash(lambdas.csv),
  },
  "thumbnail-generator": {
    dir: "benchmarks/suites/thumbnail-generator/artillery",
    ec2: hosts.thumbnail_ec2 || "thumbnail-generator-ec2.bench.local",
    ecs: hosts.thumbnail_ecs || "thumbnail-ecs.bench.local",
    lambda: stripSlash(lambdas.thumbnail),
  },
};

for (const [name, cfg] of Object.entries(apps)) {
  const dir = path.join(root, cfg.dir);
  if (!fs.existsSync(dir)) continue;
  const files = {
    "test-ec2.yml": { kind: "alb", host: cfg.ec2 },
    "test-ecs.yml": { kind: "alb", host: cfg.ecs },
    "test-lambda.yml": { kind: "lambda", url: cfg.lambda },
  };
  for (const [fname, meta] of Object.entries(files)) {
    const fp = path.join(dir, fname);
    if (!fs.existsSync(fp)) continue;
    let text = fs.readFileSync(fp, "utf8");
    if (meta.kind === "alb") {
      text = setComment(text, "# ALB + Host header (synced from terraform outputs)");
      text = setTarget(text, albUrl);
      text = setHost(text, meta.host);
    } else {
      if (!meta.url) {
        console.warn("WARN: no lambda url for", name);
        continue;
      }
      text = setComment(text, "# Lambda Function URL (synced from terraform outputs)");
      text = setTarget(text, meta.url);
    }
    fs.writeFileSync(fp, text);
    console.log("updated", path.relative(root, fp));
  }
}

// prometheus lambda target host
const prom = path.join(root, "benchmarks/suites/anilove/prometheus.yml");
const lamHost = stripSlash(lambdas.anilove || "").replace(/^https?:\/\//, "");
if (fs.existsSync(prom) && lamHost) {
  let p = fs.readFileSync(prom, "utf8");
  p = p.replace(
    /(job_name: instrumented-metrics-lambda[\s\S]*?targets:\s*\[\s*")[^"]+(")/,
    `$1${lamHost}$2`
  );
  fs.writeFileSync(prom, p);
  console.log("updated", path.relative(root, prom));
}

console.log("");
console.log("ALB:", albUrl);
console.log("Done. Restart metrics-proxy if it was running.");
NODE
