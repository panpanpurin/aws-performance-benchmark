// Start the "total" timer only after multer finished parsing the body.
// That way EC2/ECS and Lambda Function URL measure the same phase.
const onFinished = require('on-finished');
const {
  totalExecutionTime,
  startRequestMetricsSampling,
  cpuUsagePercent,
  peakCpuUsagePercent,
  ramUsageMb,
  peakRamUsageMb,
} = require('../metrics');

function totalTimer({ operation, route }) {
  return (req, res, next) => {
    const endServiceTotal = totalExecutionTime.startTimer();
    const stopSampler = startRequestMetricsSampling();

    let finalized = false;

    const finalize = (overrideStatusCode) => {
      if (finalized) return;
      finalized = true;

      const statusCode = overrideStatusCode ?? res.statusCode;
      const status = statusCode >= 500 || statusCode === 499 ? 'error' : 'success';
      const method = req.method;

      try {
        endServiceTotal({ status, method, operation, route });
      } catch (_) {}

      try {
        const { avgCpu, peakCpu, avgRam, peakRam } = stopSampler();
        cpuUsagePercent.labels(operation).set(avgCpu);
        peakCpuUsagePercent.labels(operation).set(peakCpu);
        ramUsageMb.labels(operation).set(avgRam);
        peakRamUsageMb.labels(operation).set(peakRam);
      } catch (_) {}
    };

    onFinished(res, () => finalize());
    res.on('close', () => {
      if (!res.writableEnded) finalize(499);
    });

    next();
  };
}

module.exports = { totalTimer };
