const { Anime } = require('../models');
const { Op } = require('sequelize');

// Basic sanitization
const sanitize = (str) =>
  typeof str === 'string'
    ? str.replace(/</g, '&lt;').replace(/>/g, '&gt;').trim()
    : '';

// Input validation
const validateAnimeInput = ({ title, genre, episodes, note }, isUpdate = false) => {
  const errors = [];

  if (!isUpdate || title !== undefined) {
    if (!title || typeof title !== 'string' || title.length > 100) {
      errors.push('Title is required and must be a string up to 100 chars');
    }
  }

  if (!isUpdate || genre !== undefined) {
    if (!Array.isArray(genre) || genre.some((g) => typeof g !== 'string')) {
      errors.push('Genre must be an array of strings');
    }
  }

  if (!isUpdate || episodes !== undefined) {
    if (!Number.isInteger(episodes) || episodes <= 0) {
      errors.push('Episodes must be a positive integer');
    }
  }

  if (!isUpdate || note !== undefined) {
    if (typeof note !== 'number' || note < 0 || note > 10) {
      errors.push('Note must be a number between 0 and 10');
    }
  }

  return errors;
};

// CREATE
const createAnime = async (req, res) => {
  try {
    let { title, genre, episodes, note } = req.body;

    title = typeof title === 'string' ? title.substring(0, 100).trim() : '';
    genre = Array.isArray(genre) ? genre.map(String) : [];
    episodes = Number(episodes);
    note = Number(note);

    const errors = validateAnimeInput({ title, genre, episodes, note });
    if (errors.length > 0) return res.status(400).json({ errors });

    const sanitizedTitle = sanitize(title);
    const sanitizedGenre = genre.map(sanitize);

    const existingAnime = await Anime.findOne({ where: { title: sanitizedTitle } });
    if (existingAnime) {
      return res.status(409).json({ error: 'Anime with this title already exists' });
    }

    const anime = await Anime.create({
      title: sanitizedTitle,
      genre: sanitizedGenre,
      episodes,
      note,
    });
    res.status(201).json(anime);
  } catch (error) {
    console.error('Error in createAnime:', error);
    res.status(500).json({ error: 'Failed to create anime', details: error.message });
  }
};

// READ ALL
//
// Fixed page, not the whole table: unbounded, the cost grew with the rows in
// flight, and platforms that queue hold more of them than one that rejects.
// Seeded rows hold the lowest ids, so ordering by id returns the same page.
// Seed with make db-reset (AWS) or seedDB.js (local).
const LIST_PAGE_SIZE = Number(process.env.LIST_PAGE_SIZE || 100);

const getAllAnimes = async (_req, res) => {
  try {
    const list = await Anime.findAll({
      order: [['id', 'ASC']],
      limit: LIST_PAGE_SIZE,
    });
    res.json(list);
  } catch (error) {
    console.error('Error fetching animes:', error);
    res.status(500).json({ error: 'Failed to fetch animes', details: error.message });
  }
};

// READ BY ID
const getAnimeById = async (req, res) => {
  const rawId = req.params.id;

  if (typeof rawId !== 'string' && typeof rawId !== 'number') {
    return res.status(400).json({ error: 'Anime ID must be a number' });
  }

  const id = Number(rawId);
  if (!Number.isInteger(id) || id <= 0) {
    return res.status(400).json({ error: 'Invalid anime ID' });
  }

  try {
    const anime = await Anime.findByPk(id);
    anime ? res.json(anime) : res.status(404).json({ error: 'Anime not found' });
  } catch (error) {
    console.error('Error fetching anime by ID:', error);
    res.status(500).json({ error: 'Failed to fetch anime', details: error.message });
  }
};

// UPDATE
const updateAnime = async (req, res) => {
  const rawId = req.params.id;

  if (typeof rawId !== 'string' && typeof rawId !== 'number') {
    return res.status(400).json({ error: 'Anime ID must be a number' });
  }

  const id = Number(rawId);
  if (!Number.isInteger(id) || id <= 0) {
    return res.status(400).json({ error: 'Invalid anime ID' });
  }

  try {
    const anime = await Anime.findByPk(id);
    if (!anime) return res.status(404).json({ error: 'Anime not found' });

    let { title, genre, episodes, note } = req.body;

    title = typeof title === 'string' ? title.substring(0, 100).trim() : undefined;
    genre = Array.isArray(genre) ? genre.map(String) : undefined;
    episodes = episodes !== undefined ? Number(episodes) : undefined;
    note = note !== undefined ? Number(note) : undefined;

    const errors = validateAnimeInput({ title, genre, episodes, note }, true);
    if (errors.length > 0) return res.status(400).json({ errors });

    if (title) {
      const existingAnime = await Anime.findOne({
        where: { title: sanitize(title), id: { [Op.ne]: id } },
      });
      if (existingAnime) {
        return res.status(409).json({ error: 'Another anime with this title already exists' });
      }
    }

    const updates = {};
    if (title) updates.title = sanitize(title);
    if (genre && genre.length > 0) updates.genre = genre.map(sanitize);
    if (episodes !== undefined && !Number.isNaN(episodes)) updates.episodes = episodes;
    if (note !== undefined && !Number.isNaN(note)) updates.note = note;

    await anime.update(updates);
    res.json(anime);
  } catch (error) {
    console.error('Error in updateAnime:', error);
    res.status(500).json({ error: 'Failed to update anime', details: error.message });
  }
};

// DELETE
const deleteAnime = async (req, res) => {
  const rawId = req.params.id;

  if (typeof rawId !== 'string' && typeof rawId !== 'number') {
    return res.status(400).json({ error: 'Anime ID must be a number' });
  }

  const id = Number(rawId);
  if (!Number.isInteger(id) || id <= 0) {
    return res.status(400).json({ error: 'Invalid anime ID' });
  }

  try {
    const anime = await Anime.findByPk(id);
    if (!anime) return res.status(404).json({ error: 'Anime not found' });

    await anime.destroy();
    res.status(204).end();
  } catch (error) {
    console.error('Error in deleteAnime:', error);
    res.status(500).json({ error: 'Failed to delete anime', details: error.message });
  }
};

module.exports = {
  createAnime,
  getAllAnimes,
  getAnimeById,
  updateAnime,
  deleteAnime,
};
