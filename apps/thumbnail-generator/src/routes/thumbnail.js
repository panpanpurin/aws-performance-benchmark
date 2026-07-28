// src/routes/thumbnail.js
const express = require('express');
const router = express.Router();

const upload = require('../middlewares/upload');
const { totalTimer } = require('../middlewares/totalTimer');
const { generateThumbnail } = require('../controllers/thumbnailController');

// Parse body with multer before totalTimer so total latency is comparable across platforms
router.post(
  '/',
  upload.single('image'),
  totalTimer({ operation: 'generate_thumbnail', route: '/thumbnail' }),
  generateThumbnail
);

module.exports = router;
