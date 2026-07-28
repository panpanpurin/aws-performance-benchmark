// Prometheus metrics shared across EC2, ECS, and Lambda (identical names for Grafana)
const express = require('express');
const client = require('prom-client');
const os = require('os');
const { AsyncLocalStorage } = require('async_hooks');

// Cold-start metrics apply when Lambda runtime env vars are present
const isLambda = !!(
  process.env.AWS_LAMBDA_FUNCTION_NAME ||
  process.env.LAMBDA_TASK_ROOT
);

const register = new client.Registry();
register.setDefaultLabels({
  service: process.env.SERVICE_NAME || 'anilove',
  environment: process.env.NODE_ENV || 'production',
});

client.collectDefaultMetrics({
  register,
  prefix: 'anilove_',
});

const als = new AsyncLocalStorage();

// cold start: only meaningful on Lambda (first invoke after a new container)
const lambdaInitHr = process.hrtime.bigint();
let coldStartRecorded = false;

const coldStartDuration = new client.Histogram({
  name: 'app_cold_start_duration_seconds',
  help: 'Time from runtime init to first handler invocation (cold start)',
  labelNames: ['function', 'region', 'memory_mb', 'runtime'],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10],
});
register.registerMetric(coldStartDuration);

function recordColdStartOnce() {
  if (!isLambda || coldStartRecorded) return;
  coldStartRecorded = true;
  const end = process.hrtime.bigint();
  const seconds = Number(end - lambdaInitHr) / 1e9;
  coldStartDuration
    .labels(
      process.env.AWS_LAMBDA_FUNCTION_NAME || 'local',
      process.env.AWS_REGION || 'local',
      String(process.env.AWS_LAMBDA_FUNCTION_MEMORY_SIZE || ''),
      process.version
    )
    .observe(seconds);
}

// ---- Request histograms ----
const httpRequestDuration = new client.Histogram({
  name: 'app_total_execution_time_seconds',
  help: 'Total request time (Express: start to finish)',
  labelNames: ['route', 'method', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
});

const internalProcessingDuration = new client.Histogram({
  name: 'app_internal_processing_time_seconds',
  help: 'Request time minus DB time (app-only)',
  labelNames: ['route', 'method', 'status_code'],
  buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
});

register.registerMetric(httpRequestDuration);
register.registerMetric(internalProcessingDuration);

// ---- CPU / RAM gauges ----
const cpuPercentGauge = new client.Gauge({
  name: 'app_cpu_usage_percent',
  help: 'Estimated per-process CPU usage percent over the last interval',
});
const cpuPercentPeakGauge = new client.Gauge({
  name: 'app_cpu_peak_percent',
  help: 'Peak CPU percent observed since process start',
});
const rssGauge = new client.Gauge({
  name: 'app_ram_usage_mb',
  help: 'Resident Set Size (MB)',
});
const rssPeakGauge = new client.Gauge({
  name: 'app_ram_peak_mb',
  help: 'Peak Resident Set Size (MB)',
});

register.registerMetric(cpuPercentGauge);
register.registerMetric(cpuPercentPeakGauge);
register.registerMetric(rssGauge);
register.registerMetric(rssPeakGauge);

let lastCpuUsage = process.cpuUsage();
let lastHrtime = process.hrtime.bigint();
let cpuPeak = 0;
let rssPeak = 0;
const CPU_INTERVAL_MS = 5000;

setInterval(() => {
  const nowHr = process.hrtime.bigint();
  const elapsedNs = Number(nowHr - lastHrtime);
  lastHrtime = nowHr;

  const current = process.cpuUsage();
  const deltaUser = current.user - lastCpuUsage.user;
  const deltaSys = current.system - lastCpuUsage.system;
  lastCpuUsage = current;

  const deltaTotalUs = deltaUser + deltaSys;
  const elapsedSec = elapsedNs / 1e9;
  const cpuCores = os.cpus().length || 1;

  const cpuPercent = (deltaTotalUs / 1e6) / elapsedSec / cpuCores * 100;
  cpuPercentGauge.set(cpuPercent);
  if (cpuPercent > cpuPeak) {
    cpuPeak = cpuPercent;
    cpuPercentPeakGauge.set(cpuPeak);
  }

  const rssMb = process.memoryUsage().rss / (1024 * 1024);
  rssGauge.set(rssMb);
  if (rssMb > rssPeak) {
    rssPeak = rssMb;
    rssPeakGauge.set(rssPeak);
  }
}, CPU_INTERVAL_MS).unref();

function normalizeRoute(req) {
  let base = (req.baseUrl || '') + (req.route?.path || '');
  if (!base || base === '') {
    base = req.path || req.originalUrl || '';
  }
  base = base.split('?')[0]
    .replace(/[0-9a-fA-F-]{36}/g, ':uuid')
    .replace(/\b\d+\b/g, ':id');
  if (base.length > 1 && base.endsWith('/')) base = base.slice(0, -1);
  if (base && !base.startsWith('/')) base = '/' + base;
  return base || '/';
}

function requestTimingMiddleware(req, res, next) {
  if (req.path.startsWith('/metrics') || req.path.startsWith('/health')) return next();
  if (req.method === 'HEAD' || req.method === 'OPTIONS') return next();

  const isAnimes = req.path.startsWith('/animes');
  const isCrud = ['GET', 'POST', 'PUT', 'DELETE'].includes(req.method);
  if (!isAnimes || !isCrud) return next();

  const store = { dbMs: 0, startHr: process.hrtime.bigint() };

  als.run(store, () => {
    res.on('finish', () => {
      if (res.headersSent === false) return;
      const endHr = process.hrtime.bigint();
      const totalMs = Number(endHr - store.startHr) / 1e6;
      const route = normalizeRoute(req);
      const totalSec = totalMs / 1000;
      const internalSec = Math.max(0, totalMs - (store.dbMs || 0)) / 1000;

      httpRequestDuration.labels(route, req.method, String(res.statusCode)).observe(totalSec);
      internalProcessingDuration.labels(route, req.method, String(res.statusCode)).observe(internalSec);
    });

    res.on('close', () => {
      if (res.writableEnded) return;
      const endHr = process.hrtime.bigint();
      const totalMs = Number(endHr - store.startHr) / 1e6;
      const route = normalizeRoute(req);
      const totalSec = totalMs / 1000;
      const internalSec = Math.max(0, totalMs - (store.dbMs || 0)) / 1000;
      const status = String(res.statusCode || 499);

      httpRequestDuration.labels(route, req.method, status).observe(totalSec);
      internalProcessingDuration.labels(route, req.method, status).observe(internalSec);
    });

    next();
  });
}

function sequelizeLogger(_sql, timingMs) {
  if (typeof timingMs === 'number') {
    const store = als.getStore();
    if (store) store.dbMs = (store.dbMs || 0) + timingMs;
  }
}

const metricsRouter = express.Router();
metricsRouter.get('/metrics', async (_req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).send(err.message || 'metrics error');
  }
});

module.exports = {
  register,
  metricsRouter,
  requestTimingMiddleware,
  sequelizeLogger,
  recordColdStartOnce,
  isLambda,
};
