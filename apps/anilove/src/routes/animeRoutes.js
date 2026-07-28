const express = require('express');
const router = express.Router();
const {
  createAnime,
  getAllAnimes,
  getAnimeById,
  updateAnime,
  deleteAnime,
} = require('../controllers/animeController');

router.get('/', getAllAnimes);
router.get('/:id', getAnimeById);
router.post('/', createAnime);
router.put('/:id', updateAnime);
router.delete('/:id', deleteAnime);

module.exports = router;
