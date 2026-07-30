// Reverse proxy so Prometheus can scrape AniLove EC2/ECS /metrics via ALB Host headers.
// Prometheus cannot set the Host header itself.
//
//   node scripts/anilove-metrics-proxy.js
//   make metrics-proxy
//
//   18080 -> Host: anilove-ec2.bench.local
//   18081 -> Host: anilove-ecs.bench.local
//
// Optional: ALB_HOST=my-alb.amazonaws.com node scripts/anilove-metrics-proxy.js
// Also reads terraform/generated/benchmark-targets.json when present.

const http = require("http");
const fs = require("fs");
const path = require("path");

function loadAlbFromTargets() {
  try {
    const p = path.join(__dirname, "..", "terraform", "generated", "benchmark-targets.json");
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    return j.alb_dns || null;
  } catch {
    return null;
  }
}

const ALB =
  process.env.ALB_HOST ||
  loadAlbFromTargets() ||
  "aws-perf-bench-apps-1451786047.ap-northeast-1.elb.amazonaws.com";

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

startProxy(18080, "anilove-ec2.bench.local");
startProxy(18081, "anilove-ecs.bench.local");
console.log("Leave this process running while Grafana scrapes app metrics.");
console.log("Ctrl+C to stop.");
