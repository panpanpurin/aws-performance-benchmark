// Thumbnail Prometheus metrics (shared names across platforms for Grafana)
const client = require('prom-client');
const os = require('os');

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

const totalExecutionTime = new client.Histogram({
  name: 'app_total_execution_time_seconds',
  help: 'Total application execution time per request (post-body parsing to res.finish)',
  labelNames: ['status', 'method', 'operation', 'route'],
  buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
});

const thumbnailProcessingDurationSeconds = new client.Histogram({
  name: 'app_internal_processing_time_seconds',
  help: 'Time to generate a thumbnail in seconds (internal only)',
  labelNames: ['status', 'method', 'operation', 'format'],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
});

const cpuUsagePercent = new client.Gauge({
  name: 'app_cpu_usage_percent',
  help: 'Average CPU usage percentage of the Node.js process during the request',
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

const coldStartHistogram = new client.Histogram({
  name: 'app_cold_start_duration_seconds',
  help: 'Lambda cold start duration in seconds',
  buckets: [0.01, 0.05, 0.1, 0.2, 0.5, 1, 2],
});

register.registerMetric(totalExecutionTime);
register.registerMetric(thumbnailProcessingDurationSeconds);
register.registerMetric(cpuUsagePercent);
register.registerMetric(peakCpuUsagePercent);
register.registerMetric(ramUsageMb);
register.registerMetric(peakRamUsageMb);
register.registerMetric(coldStartHistogram);

if (!isLambda) {
  client.collectDefaultMetrics({ register });
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
  const vcpus = os.cpus().length || 1;

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
  recordColdStartIfNeeded,
  startRequestMetricsSampling,
  startSystemMetricsSampling,
};
