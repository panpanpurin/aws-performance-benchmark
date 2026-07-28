const express = require('express');
const router = express.Router({ mergeParams: true });
const {
  getUserList,
  addToList,
  updateListEntry,
  removeFromList,
} = require('../controllers/userAnimeListController');
const authenticate = require('../middlewares/authMiddleware');

// GET /users/:id/list
router.get('/', authenticate, getUserList);

// POST /users/:id/list
router.post('/', authenticate, addToList);

// PUT /users/:id/list/:animeId
router.put('/:animeId', authenticate, updateListEntry);

// DELETE /users/:id/list/:animeId
router.delete('/:animeId', authenticate, removeFromList);

module.exports = router;
