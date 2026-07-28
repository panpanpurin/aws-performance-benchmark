const { DataTypes } = require('sequelize');
const sequelize = require('../config/database');
const tableOptions = require('./tableOptions');

const UserAnimeList = sequelize.define(
  'UserAnimeList',
  {
    status: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    note: {
      type: DataTypes.INTEGER,
      validate: {
        min: 0,
        max: 10,
      },
    },
  },
  tableOptions
);

module.exports = UserAnimeList;
