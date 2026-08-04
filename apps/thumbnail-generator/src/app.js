const express = require('express');
const app = express();

const { register, syncCpuSecondsCounter } = require('./metrics');
const thumbnailRoutes = require('./routes/thumbnail');

app.use(express.json());

app.get('/health', (_req, res) => res.status(200).json({ status: 'ok' }));

app.use('/thumbnail', thumbnailRoutes);

app.get('/metrics', async (_req, res) => {
  try {
    // Keep the counter current at scrape time.
    syncCpuSecondsCounter();
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    console.error('[Metrics] Failed to generate metrics:', err);
    res.status(500).json({ error: 'Failed to generate metrics' });
  }
});

app.use((err, _req, res, _next) => {
  if (err.name === 'MulterError' || (err.message && err.message.includes('Unsupported file format'))) {
    return res.status(400).json({ error: err.message });
  }
  console.error('[Unhandled Error]', err);
  res.status(500).json({ error: 'Internal Server Error' });
});

module.exports = app;
