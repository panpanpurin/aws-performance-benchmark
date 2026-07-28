const { DataTypes } = require('sequelize');
const sequelize = require('../config/database');
const tableOptions = require('./tableOptions');

const Anime = sequelize.define(
  'Anime',
  {
    title: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    genre: {
      type: DataTypes.ARRAY(DataTypes.STRING),
      allowNull: false,
    },
    episodes: {
      type: DataTypes.INTEGER,
    },
    note: {
      type: DataTypes.FLOAT,
    },
  },
  tableOptions
);

module.exports = Anime;
