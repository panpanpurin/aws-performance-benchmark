const sharp = require('sharp');
const { thumbnailProcessingDurationSeconds } = require('../metrics');

// Fair 1-vCPU comparison across EC2 / ECS / Lambda
sharp.cache(false);
sharp.concurrency(1);

// app_internal_processing_time_seconds covers the sharp pipeline only.
exports.generateThumbnail = async (req, res) => {
  let outputFormat = 'jpeg';

  const method = 'POST';
  const operation = 'generate_thumbnail';

  try {
    if (!req.file) {
      console.log('[Thumbnail] Request failed - no image uploaded.');
      return res.status(400).json({ error: 'No image file uploaded.' });
    }

    let { width = 200, height = 200, format = 'jpeg', quality = 80 } = req.query;

    outputFormat = String(format || '').toLowerCase();
    if (outputFormat === 'jpg') outputFormat = 'jpeg';
    if (!['jpeg', 'png', 'webp'].includes(outputFormat)) {
      console.log(`[Thumbnail] Request failed - invalid format "${outputFormat}".`);
      return res.status(400).json({ error: 'Invalid image format.' });
    }

    width = parseInt(width, 10);
    height = parseInt(height, 10);
    quality = parseInt(quality, 10);

    if (Number.isNaN(width) || Number.isNaN(height) || Number.isNaN(quality)) {
      return res.status(400).json({ error: 'Width, height, and quality must be numbers.' });
    }

    if (width <= 0 || height <= 0) {
      return res.status(400).json({ error: 'Width and height must be greater than 0.' });
    }

    if (quality < 1 || quality > 100) {
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

    // toBuffer, not pipe(res): a piped response only ends once the socket
    // drains, which puts egress inside the timer. It also drops the second
    // decode the old clone().metadata() call did just to read dimensions.
    const timer = thumbnailProcessingDurationSeconds.startTimer();
    let output;
    try {
      output = await transformer.toBuffer({ resolveWithObject: true });
    } catch (err) {
      timer({ status: 'error', method, operation, format: outputFormat });
      console.error(`[Thumbnail] ERROR - format: ${outputFormat}, size: ${width}x${height}, reason: ${err.message}`);
      if (!res.headersSent) {
        res.status(500).json({ error: 'Failed to process image.', details: err.message });
      }
      return;
    }
    const internalSeconds = timer({ status: 'success', method, operation, format: outputFormat });

    // info is the output image. metadata() described the input, so these
    // headers used to report the source dimensions.
    res.set('Content-Type', `image/${outputFormat}`);
    res.set('X-Image-Width', output.info.width);
    res.set('X-Image-Height', output.info.height);
    res.send(output.data);

    console.log(
      `[Thumbnail] SUCCESS - format: ${outputFormat}, size: ${width}x${height}, sharp took ${(internalSeconds * 1000).toFixed(2)}ms`
    );
  } catch (error) {
    const errorMsg = error.message || 'Unexpected error';
    console.error(`[Thumbnail] ERROR - ${errorMsg}`);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Unexpected processing error.', details: errorMsg });
    }
  }
};
