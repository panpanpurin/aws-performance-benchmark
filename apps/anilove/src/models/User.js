const { DataTypes } = require('sequelize');
const sequelize = require('../config/database');
const tableOptions = require('./tableOptions');

const User = sequelize.define(
  'User',
  {
    name: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    email: {
      type: DataTypes.STRING,
      unique: true,
      allowNull: false,
    },
    password: {
      type: DataTypes.STRING,
      allowNull: false,
    },
  },
  tableOptions
);

module.exports = User;
