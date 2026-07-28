const sharp = require('sharp');
const { thumbnailProcessingDurationSeconds } = require('../metrics');

// Fair 1-vCPU comparison across EC2 / ECS / Lambda
sharp.cache(false);
sharp.concurrency(1);

exports.generateThumbnail = async (req, res) => {
  const timer = thumbnailProcessingDurationSeconds.startTimer();
  let outputFormat = 'jpeg';
  const startTime = process.hrtime();
  let finalized = false;

  const method = 'POST';
  const operation = 'generate_thumbnail';

  try {
    if (!req.file) {
      console.log('[Thumbnail] Request failed - no image uploaded.');
      try {
        timer({ status: 'error', method, operation, format: 'none' });
      } catch (_) {}
      return res.status(400).json({ error: 'No image file uploaded.' });
    }

    let { width = 200, height = 200, format = 'jpeg', quality = 80 } = req.query;

    outputFormat = String(format || '').toLowerCase();
    if (outputFormat === 'jpg') outputFormat = 'jpeg';
    if (!['jpeg', 'png', 'webp'].includes(outputFormat)) {
      console.log(`[Thumbnail] Request failed - invalid format "${outputFormat}".`);
      try {
        timer({ status: 'error', method, operation, format: outputFormat });
      } catch (_) {}
      return res.status(400).json({ error: 'Invalid image format.' });
    }

    width = parseInt(width, 10);
    height = parseInt(height, 10);
    quality = parseInt(quality, 10);

    if (Number.isNaN(width) || Number.isNaN(height) || Number.isNaN(quality)) {
      try {
        timer({ status: 'error', method, operation, format: outputFormat });
      } catch (_) {}
      return res.status(400).json({ error: 'Width, height, and quality must be numbers.' });
    }

    if (width <= 0 || height <= 0) {
      try {
        timer({ status: 'error', method, operation, format: outputFormat });
      } catch (_) {}
      return res.status(400).json({ error: 'Width and height must be greater than 0.' });
    }

    if (quality < 1 || quality > 100) {
      try {
        timer({ status: 'error', method, operation, format: outputFormat });
      } catch (_) {}
      return res.status(400).json({ error: 'Quality must be between 1 and 100.' });
    }

    let transformer = sharp(req.file.buffer).resize(width, height);

    if (outputFormat === 'png') {
      const compressionLevel = Math.max(0, Math.min(9, Math.round((9 * (100 - quality)) / 100)));
      transformer = transformer.png({ compressionLevel, force: true, progressive: false });
    } else if (outputFormat === 'jpeg') {
      transformer = transformer.jpeg({ quality, progressive: true, mozjpeg: true, force: true });
    } else {
      transformer = transformer.webp({ quality, effort: 4, force: true });
    }

    const metadata = await transformer.clone().metadata();
    res.set('Content-Type', `image/${outputFormat}`);
    res.set('X-Image-Width', metadata.width);
    res.set('X-Image-Height', metadata.height);

    transformer.pipe(res);

    const finalizeRequest = (status = 'success', errorMsg = null) => {
      if (finalized) return;
      finalized = true;

      const [sec, ns] = process.hrtime(startTime);
      const durationSeconds = sec + ns / 1e9;
      const durationMs = (durationSeconds * 1000).toFixed(2);

      try {
        timer({ status, method, operation, format: outputFormat });
      } catch (_) {}

      const label = status === 'success' ? 'SUCCESS' : 'ERROR';
      const msg = `[Thumbnail] ${label} - format: ${outputFormat}, size: ${width}x${height}, took ${durationSeconds.toFixed(3)}s (${durationMs}ms)${errorMsg ? `, reason: ${errorMsg}` : ''}`;
      status === 'success' ? console.log(msg) : console.error(msg);
    };

    transformer.on('error', (err) => {
      finalizeRequest('error', err.message);
      if (!res.headersSent) {
        res.status(500).json({ error: 'Failed to process image.', details: err.message });
      }
    });

    res.on('finish', () => finalizeRequest('success'));
  } catch (error) {
    const errorMsg = error.message || 'Unexpected error';
    console.error(`[Thumbnail] ERROR - ${errorMsg}`);
    try {
      timer({ status: 'error', method: 'POST', operation: 'generate_thumbnail', format: outputFormat });
    } catch (_) {}
    if (!res.headersSent) {
      res.status(500).json({ error: 'Unexpected processing error.', details: errorMsg });
    }
  }
};
