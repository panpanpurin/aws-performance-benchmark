const sequelize = require('./config/database');
const { dbSchema } = require('./config/database');
require('./models');

async function syncDatabase() {
  try {
    if (dbSchema && dbSchema !== 'public') {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(dbSchema)) {
        throw new Error(`Invalid DB_SCHEMA: ${dbSchema}`);
      }
      await sequelize.query(`CREATE SCHEMA IF NOT EXISTS "${dbSchema}"`);
      console.log(`Schema ready: ${dbSchema}`);
    }
    await sequelize.sync({ force: true });
    console.log(`Database synchronized successfully! (schema=${dbSchema})`);
    process.exit(0);
  } catch (error) {
    console.error('Error synchronizing database:', error);
    process.exit(1);
  }
}

syncDatabase();
