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
const scheme = targets.scheme === "https" ? "https" : "http";
const albUrl = `${scheme}://${albDns}`;
const hosts = targets.hostnames || {};
const lambdas = targets.lambda_urls || {};
// With the functions registered as ALB targets, the load test reaches all
// three platforms through the same load balancer and the same request path.
// The Function URLs stay published either way and remain what Prometheus
// scrapes for /metrics.
const lambdaBehindAlb = targets.lambda_behind_alb === true;

function stripSlash(u) {
  return (u || "").replace(/\/$/, "");
}

function setTarget(text, url) {
  return text.replace(/^(\s*target:\s*)(["']).*\2/m, `$1"${url}"`);
}

// On HTTPS the target carries the hostname, so the header is redundant.
function removeHost(text) {
  return text.replace(/^\s*Host:\s*.*\r?\n/m, "");
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

// DNS labels mirror local.host_label in terraform/locals.tf.
const apps = {
  anilove: {
    dir: "benchmarks/suites/anilove/artillery",
    ec2: hosts.anilove_ec2 || "anilove-ec2.bench.local",
    ecs: hosts.anilove_ecs || "anilove-ecs.bench.local",
    lambdaHost: hosts.anilove_lambda || "anilove-lambda.bench.local",
    lambda: stripSlash(lambdas.anilove),
  },
  "csv-processor": {
    dir: "benchmarks/suites/csv-processor/artillery",
    ec2: hosts.csv_ec2 || "csv-ec2.bench.local",
    ecs: hosts.csv_ecs || "csv-ecs.bench.local",
    lambdaHost: hosts.csv_lambda || "csv-lambda.bench.local",
    lambda: stripSlash(lambdas.csv),
  },
  "thumbnail-generator": {
    dir: "benchmarks/suites/thumbnail-generator/artillery",
    ec2: hosts.thumbnail_ec2 || "thumb-ec2.bench.local",
    ecs: hosts.thumbnail_ecs || "thumb-ecs.bench.local",
    lambdaHost: hosts.thumbnail_lambda || "thumb-lambda.bench.local",
    lambda: stripSlash(lambdas.thumbnail),
  },
};

for (const [name, cfg] of Object.entries(apps)) {
  const dir = path.join(root, cfg.dir);
  if (!fs.existsSync(dir)) continue;
  const files = {
    "test-ec2.yml": { kind: "alb", host: cfg.ec2 },
    "test-ecs.yml": { kind: "alb", host: cfg.ecs },
    "test-lambda.yml": lambdaBehindAlb
      ? { kind: "alb", host: cfg.lambdaHost }
      : { kind: "lambda", url: cfg.lambda },
  };
  for (const [fname, meta] of Object.entries(files)) {
    const fp = path.join(dir, fname);
    if (!fs.existsSync(fp)) continue;
    let text = fs.readFileSync(fp, "utf8");
    if (meta.kind === "alb" && scheme === "https") {
      text = setComment(text, "# ALB over HTTPS (synced from terraform outputs)");
      text = setTarget(text, `https://${meta.host}`);
      text = removeHost(text);
    } else if (meta.kind === "alb") {
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

// Prometheus scrape targets, one file per suite. EC2/ECS go straight at the
// ALB hostnames on HTTPS, through the metrics proxy on HTTP.
const promSuites = {
  anilove: "anilove",
  "csv-processor": "csv",
  "thumbnail-generator": "thumbnail",
};

// Proxy port per suite and platform, mirroring scripts/metrics-proxy.js.
const proxyPorts = {
  anilove: { ec2: 18080, ecs: 18081 },
  csv: { ec2: 18082, ecs: 18083 },
  thumbnail: { ec2: 18084, ecs: 18085 },
};

// Rewrites a job's targets and the scheme line under job_name. Matches empty
// and filled lists, so first sync and re-sync both work.
function setPromJob(text, job, target, https) {
  const tgtRe = new RegExp(`(job_name: ${job}[\\s\\S]*?targets:\\s*)\\[[^\\]]*\\]`);
  if (!tgtRe.test(text)) return null;
  let out = text.replace(tgtRe, `$1["${target}"]`);
  const schemeRe = new RegExp(`(job_name: ${job}\\r?\\n)(\\s*scheme:\\s*\\w+\\r?\\n)?`);
  return out.replace(schemeRe, https ? `$1    scheme: https\n` : "$1");
}

for (const [dir, key] of Object.entries(promSuites)) {
  const prom = path.join(root, "benchmarks/suites", dir, "prometheus.yml");
  if (!fs.existsSync(prom)) continue;
  let p = fs.readFileSync(prom, "utf8");
  const cfg = apps[dir];
  const https = scheme === "https";

  for (const platform of ["ec2", "ecs"]) {
    const target = https
      ? cfg[platform]
      : `host.docker.internal:${proxyPorts[key][platform]}`;
    const next = setPromJob(p, `instrumented-metrics-${platform}`, target, https);
    if (next === null) {
      console.log(`WARN could not locate instrumented-metrics-${platform} targets in`, dir);
      continue;
    }
    p = next;
  }

  const lamHost = stripSlash(lambdas[key] || "").replace(/^https?:\/\//, "");
  if (lamHost) {
    const re = /(job_name: instrumented-metrics-lambda[\s\S]*?targets:\s*)\[[^\]]*\]/;
    if (re.test(p)) p = p.replace(re, `$1["${lamHost}"]`);
    else console.log("WARN could not locate instrumented-metrics-lambda targets in", dir);
  } else {
    console.log("WARN no Lambda URL for", key, "- leaving its scrape target alone");
  }

  fs.writeFileSync(prom, p);
  console.log("updated", path.relative(root, prom));
}

console.log("");
console.log("ALB:", albUrl);
console.log(
  "Lambda load path:",
  lambdaBehindAlb ? "ALB (same as EC2/ECS)" : "Function URL"
);
if (scheme === "https") {
  console.log("Done. Prometheus scrapes the ALB directly - metrics-proxy not needed.");
} else {
  console.log("Done. Restart metrics-proxy if it was running.");
}
NODE
