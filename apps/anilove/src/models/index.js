const Anime = require('./Anime');
const User = require('./User');
const UserAnimeList = require('./UserAnimeList');

// One user has many anime entries
User.hasMany(UserAnimeList, { foreignKey: 'userId', onDelete: 'CASCADE' });
UserAnimeList.belongsTo(User, { foreignKey: 'userId' });

// One anime can be listed by many users
Anime.hasMany(UserAnimeList, { foreignKey: 'animeId', onDelete: 'CASCADE' });
UserAnimeList.belongsTo(Anime, { foreignKey: 'animeId' });

module.exports = {
  Anime,
  User,
  UserAnimeList,
};
