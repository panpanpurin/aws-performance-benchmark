const { UserAnimeList, Anime } = require('../models');

const getUserList = async (req, res) => {
  try {
    const userId = req.params.id;
    const list = await UserAnimeList.findAll({
      where: { userId },
      include: Anime,
    });
    res.json(list);
  } catch {
    res.status(500).json({ error: 'Failed to retrieve list' });
  }
};

const addToList = async (req, res) => {
  try {
    const userId = req.params.id;
    const { animeId, status, note } = req.body;

    console.log('Received addToList request:', { userId, animeId, status, note });

    const animeExists = await Anime.findByPk(animeId);
    if (!animeExists) {
      return res.status(404).json({ error: 'Anime not found' });
    }

    const userExists = await require('../models/User').findByPk(userId);
    if (!userExists) {
      return res.status(404).json({ error: 'User not found' });
    }

    const entry = await UserAnimeList.create({
      userId,
      animeId,
      status,
      note,
    });

    res.status(201).json(entry);
  } catch (error) {
    console.error('Error in addToList:', error);
    res.status(500).json({ error: 'Failed to add to list', details: error.message });
  }
};

const updateListEntry = async (req, res) => {
  try {
    const { id: userId, animeId } = req.params;
    const { status, note } = req.body;

    const entry = await UserAnimeList.findOne({
      where: { userId, animeId },
    });

    if (!entry) return res.status(404).json({ message: 'Entry not found' });

    entry.status = status;
    entry.note = note;
    await entry.save();

    res.json(entry);
  } catch {
    res.status(500).json({ error: 'Failed to update list entry' });
  }
};

const removeFromList = async (req, res) => {
  try {
    const { id: userId, animeId } = req.params;

    const entry = await UserAnimeList.findOne({
      where: { userId, animeId },
    });

    if (!entry) return res.status(404).json({ message: 'Entry not found' });

    await entry.destroy();
    res.status(204).end();
  } catch {
    res.status(500).json({ error: 'Failed to remove from list' });
  }
};

module.exports = {
  getUserList,
  addToList,
  updateListEntry,
  removeFromList,
};
