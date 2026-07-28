// Models use the schema from DB_SCHEMA so EC2, ECS, and Lambda
// can share one RDS database with isolated tables.
const { dbSchema } = require('../config/database');

module.exports = {
  schema: dbSchema,
};
