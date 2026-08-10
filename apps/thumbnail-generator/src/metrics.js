// Thumbnail Prometheus metrics (shared names across platforms for Grafana)
const client = require('prom-client');

const isLambda = !!(
  process.env.AWS_LAMBDA_FUNCTION_NAME ||
  process.env.LAMBDA_TASK_ROOT
);

const register = new client.Registry();

register.setDefaultLabels({
  service:
    process.env.SERVICE_NAME ||
    process.env.LAMBDA_FUNCTION_NAME ||
    process.env.AWS_LAMBDA_FUNCTION_NAME ||
    'thumbnail-generator',
  environment: process.env.NODE_ENV || 'production',
});

// Sized from pilot 20260808-183300, phase 2. histogram_quantile interpolates
// linearly inside whichever bucket a quantile falls in, so a bucket wider than
// the effect being measured yields a fabricated percentile, and the resolution
// is lost at observation time - no PromQL recovers it afterwards.
//
// The previous edges put 411 of 414 EC2 requests, and all 397 Lambda requests,
// inside a single bucket. Measured means were EC2 77 ms, ECS 80 ms, Lambda
// 120 ms in-app, so 5 ms steps cover where EC2/ECS sit and 10 ms steps cover
// Lambda and the tails. Internal processing time shares these edges and runs
// lower, hence the retained coverage below 60 ms.
const LATENCY_BUCKETS = [
  0.01, 0.02, 0.03, 0.04, 0.05,
  0.06, 0.065, 0.07, 0.075, 0.08, 0.085, 0.09, 0.095, 0.1,
  0.11, 0.12, 0.13, 0.14, 0.15, 0.16, 0.17, 0.18, 0.19, 0.2,
  0.25, 0.3, 0.4, 0.6, 1, 2,
];

const totalExecutionTime = new client.Histogram({
  name: 'app_total_execution_time_seconds',
  help: 'Total application execution time per request (post-body parsing to res.finish)',
  labelNames: ['status', 'method', 'operation', 'route'],
  buckets: LATENCY_BUCKETS,
});

const thumbnailProcessingDurationSeconds = new client.Histogram({
  name: 'app_internal_processing_time_seconds',
  help: 'Sharp decode + resize + encode only, excluding framework and response write',
  labelNames: ['status', 'method', 'operation', 'format'],
  buckets: LATENCY_BUCKETS,
});

// CPU is reported from this counter, not from app_cpu_usage_percent.
// The percentage samples process-wide CPU against one request's wall clock at
// 100 ms, which is a couple of samples per request and inflates under
// concurrency. Its per-request timer also costs more as concurrency rises,
// which differs between the platforms that queue and the one that rejects.
const cpuSecondsTotal = new client.Counter({
  name: 'app_cpu_seconds_total',
  help: 'Cumulative process CPU time (user+system) in seconds',
});

// Counters only move forward, so add the delta since the last sync. Called at
// every request end and every scrape: no timer runs while a sandbox is frozen.
let lastCpuSecondsSynced = 0;
function syncCpuSecondsCounter() {
  const u = process.cpuUsage();
  const totalSeconds = (u.user + u.system) / 1e6;
  const delta = totalSeconds - lastCpuSecondsSynced;
  if (delta > 0) {
    cpuSecondsTotal.inc(delta);
    lastCpuSecondsSynced = totalSeconds;
  }
}

const cpuUsagePercent = new client.Gauge({
  name: 'app_cpu_usage_percent',
  help: 'Average CPU usage percent during the request - diagnostic; see app_cpu_seconds_total',
  labelNames: ['operation'],
});

const peakCpuUsagePercent = new client.Gauge({
  name: 'app_cpu_peak_percent',
  help: 'Peak CPU usage percentage of the Node.js process during the request',
  labelNames: ['operation'],
});

const ramUsageMb = new client.Gauge({
  name: 'app_ram_usage_mb',
  help: 'Average RAM (RSS) during the request in MB',
  labelNames: ['operation'],
});

const peakRamUsageMb = new client.Gauge({
  name: 'app_ram_peak_mb',
  help: 'Peak RAM (RSS) during the request in MB',
  labelNames: ['operation'],
});

// Same edges in all three apps so cold start is comparable between workloads.
// The previous ceiling was 2 s, below where this app's cold starts land - its
// Lambda image is ~155 MB with sharp's native binaries.
const COLD_START_BUCKETS = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12];

const coldStartHistogram = new client.Histogram({
  name: 'app_cold_start_duration_seconds',
  help: 'Lambda cold start duration in seconds',
  buckets: COLD_START_BUCKETS,
});

register.registerMetric(totalExecutionTime);
register.registerMetric(thumbnailProcessingDurationSeconds);
register.registerMetric(cpuSecondsTotal);
register.registerMetric(cpuUsagePercent);
register.registerMetric(peakCpuUsagePercent);
register.registerMetric(ramUsageMb);
register.registerMetric(peakRamUsageMb);
register.registerMetric(coldStartHistogram);

if (!isLambda) {
  client.collectDefaultMetrics({ register });
}

// Peaks ratchet over the process lifetime, as in anilove and csv-processor.
// Setting them per request, as this app did before, reports whichever request
// finished last instead of the peak.
let peakCpuSeen = null;
let peakRamSeen = null;

function recordResourceSample({ operation, avgCpu, peakCpu, avgRam, peakRam }) {
  cpuUsagePercent.labels(operation).set(avgCpu);
  ramUsageMb.labels(operation).set(avgRam);

  if (peakCpuSeen === null || peakCpu > peakCpuSeen) peakCpuSeen = peakCpu;
  if (peakRamSeen === null || peakRam > peakRamSeen) peakRamSeen = peakRam;

  peakCpuUsagePercent.labels(operation).set(peakCpuSeen);
  peakRamUsageMb.labels(operation).set(peakRamSeen);
}

// Cold start (Lambda)
let isColdStart = true;
const coldStartTime = process.hrtime();

function recordColdStartIfNeeded() {
  if (!isLambda || !isColdStart) return false;
  const [sec, ns] = process.hrtime(coldStartTime);
  coldStartHistogram.observe(sec + ns / 1e9);
  isColdStart = false;
  return true;
}

// Per-request CPU/RAM sampler (EC2/ECS and Lambda)
function startRequestMetricsSampling(intervalMs = 100) {
  // Percent of the ONE vCPU this worker is allocated, on every platform.
  //
  // Not os.cpus().length: that reads the host, not the cgroup, so inside a
  // container capped with --cpus=1 on a 2-vCPU host it returns 2 and halves
  // the reported figure. Worse, the value can differ between EC2/ECS and the
  // Lambda sandbox, which would bias this metric across the platforms it is
  // meant to compare. Every platform is given exactly 1 vCPU by construction
  // (ECS task cpu=1024, EC2 --cpus=1, Lambda 1769 MB), so the divisor is 1 and
  // cannot drift. Matches the "1 vCPU semantics" the CSV app already uses.
  const vcpus = 1;

  const startCpu = process.cpuUsage();
  const startUp = process.uptime();
  const startRam = process.memoryUsage().rss / 1024 / 1024;

  let lastCpu = startCpu;
  let lastUp = startUp;

  const cpuSamples = [];
  const ramSamples = [];
  let peakCpu = 0;
  let peakRam = startRam;

  const itv = setInterval(() => {
    const curCpu = process.cpuUsage();
    const curUp = process.uptime();
    const user = (curCpu.user - lastCpu.user) / 1e6;
    const sys = (curCpu.system - lastCpu.system) / 1e6;
    const elapsed = (curUp - lastUp) || 1e-6;

    const cpu = ((user + sys) / elapsed) / vcpus * 100;
    const ram = process.memoryUsage().rss / 1024 / 1024;

    cpuSamples.push(cpu);
    ramSamples.push(ram);
    if (cpu > peakCpu) peakCpu = cpu;
    if (ram > peakRam) peakRam = ram;

    lastCpu = curCpu;
    lastUp = curUp;
  }, intervalMs);

  return () => {
    clearInterval(itv);
    syncCpuSecondsCounter();

    const endCpu = process.cpuUsage();
    const endUp = process.uptime();
    const endRam = process.memoryUsage().rss / 1024 / 1024;

    const totalUser = (endCpu.user - startCpu.user) / 1e6;
    const totalSys = (endCpu.system - startCpu.system) / 1e6;
    const totalElapsed = (endUp - startUp) || 1e-6;
    const wholeCpu = ((totalUser + totalSys) / totalElapsed) / vcpus * 100;

    const avgCpu = cpuSamples.length
      ? cpuSamples.reduce((a, b) => a + b, 0) / cpuSamples.length
      : wholeCpu;
    peakCpu = cpuSamples.length ? peakCpu : wholeCpu;

    const avgRam = ramSamples.length
      ? ramSamples.reduce((a, b) => a + b, 0) / ramSamples.length
      : (startRam + endRam) / 2;
    peakRam = ramSamples.length ? peakRam : Math.max(startRam, endRam);

    return { avgCpu, peakCpu, avgRam, peakRam };
  };
}

// Alias used by Lambda-style code
const startSystemMetricsSampling = startRequestMetricsSampling;

module.exports = {
  client,
  register,
  isLambda,
  totalExecutionTime,
  thumbnailProcessingDurationSeconds,
  cpuUsagePercent,
  peakCpuUsagePercent,
  // aliases for EC2 totalTimer naming
  cpuPeakPercent: peakCpuUsagePercent,
  ramUsageMb,
  peakRamUsageMb,
  ramPeakMb: peakRamUsageMb,
  coldStartHistogram,
  cpuSecondsTotal,
  recordResourceSample,
  syncCpuSecondsCounter,
  recordColdStartIfNeeded,
  startRequestMetricsSampling,
  startSystemMetricsSampling,
};
