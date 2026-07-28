const { Sequelize } = require('sequelize');
require('dotenv').config();
const { sequelizeLogger } = require('../metrics');

// TLS is enabled by default (required for AWS RDS).
// Disable only for local Docker Postgres: DB_SSL=false.
// Set DB_SSL_REJECT_UNAUTHORIZED=true when verifying the Amazon RDS CA.
const useSsl = process.env.DB_SSL !== 'false' && process.env.DB_SSL !== '0';
const rejectUnauthorized =
  process.env.DB_SSL_REJECT_UNAUTHORIZED === 'true' ||
  process.env.DB_SSL_REJECT_UNAUTHORIZED === '1';

// Shared RDS with one schema per compute environment for isolation.
// Values: ec2 | ecs | lambda | public (local default)
const dbSchema = (process.env.DB_SCHEMA || 'public').trim() || 'public';

const sequelize = new Sequelize(
  process.env.DB_NAME,
  process.env.DB_USER,
  process.env.DB_PASSWORD,
  {
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT || 5432),
    dialect: 'postgres',
    schema: dbSchema,
    benchmark: true, // enables DB timing for internal-vs-total metrics
    logging: sequelizeLogger,
    dialectOptions: useSsl
      ? {
          ssl: {
            require: true,
            rejectUnauthorized,
          },
        }
      : {},
    pool: {
      max: Number(process.env.DB_POOL_MAX || 20),
      min: Number(process.env.DB_POOL_MIN || 0),
      acquire: 20000,
      idle: 10000,
    },
  }
);

module.exports = sequelize;
module.exports.dbSchema = dbSchema;
module.exports.useSsl = useSsl;
