// Reverse proxy so Prometheus can scrape EC2/ECS /metrics through the ALB.
//
// Prometheus cannot set a Host header and the ALB routes by hostname. Without a
// registered domain the hostnames are *.bench.local and resolve nowhere, so one
// port per app+platform forwards to the ALB with the right Host.
//
// HTTP-only stacks. With domain_name set this exits immediately.
//
//   node scripts/metrics-proxy.js
//   make metrics-proxy
//
//   18080 -> anilove-ec2      18081 -> anilove-ecs
//   18082 -> csv-ec2          18083 -> csv-ecs
//   18084 -> thumb-ec2        18085 -> thumb-ecs
//
// Lambda is not proxied: Function URLs are real DNS names.
//
// Optional: ALB_HOST=my-alb.amazonaws.com node scripts/metrics-proxy.js
// Otherwise reads terraform/generated/benchmark-targets.json.

const http = require("http");
const fs = require("fs");
const path = require("path");

function loadTargets() {
  try {
    const p = path.join(__dirname, "..", "terraform", "generated", "benchmark-targets.json");
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return {};
  }
}

const targets = loadTargets();

// The hostnames resolve, so Prometheus scrapes the ALB directly.
if (targets.scheme === "https") {
  console.log("Domain configured: Prometheus scrapes the ALB directly.");
  console.log("This proxy is only needed on an HTTP-only ALB. Nothing to do.");
  process.exit(0);
}

const ALB = process.env.ALB_HOST || targets.alb_dns || null;

if (!ALB) {
  console.error("No ALB hostname. Run terraform apply first, or set ALB_HOST.");
  process.exit(1);
}

// Hosts match terraform/locals.tf.
const ROUTES = [
  [18080, "anilove-ec2.bench.local"],
  [18081, "anilove-ecs.bench.local"],
  [18082, "csv-ec2.bench.local"],
  [18083, "csv-ecs.bench.local"],
  [18084, "thumb-ec2.bench.local"],
  [18085, "thumb-ecs.bench.local"],
];

function startProxy(port, hostHeader) {
  http
    .createServer((req, res) => {
      const headers = { ...req.headers, host: hostHeader };
      delete headers["content-length"];
      const opts = {
        hostname: ALB,
        port: 80,
        path: req.url,
        method: req.method,
        headers,
        timeout: 15000,
      };
      const upstream = http.request(opts, (up) => {
        res.writeHead(up.statusCode || 502, up.headers);
        up.pipe(res);
      });
      upstream.on("timeout", () => {
        upstream.destroy();
        if (!res.headersSent) {
          res.statusCode = 504;
          res.end("proxy timeout");
        }
      });
      upstream.on("error", (err) => {
        if (!res.headersSent) {
          res.statusCode = 502;
          res.end("proxy error: " + err.message);
        }
      });
      req.pipe(upstream);
    })
    .listen(port, "0.0.0.0", () => {
      console.log(`:${port} -> http://${ALB} (Host: ${hostHeader})`);
    });
}

for (const [port, host] of ROUTES) startProxy(port, host);

console.log("");
console.log("Leave this process running while any suite scrapes app metrics.");
console.log("Ctrl+C to stop.");
