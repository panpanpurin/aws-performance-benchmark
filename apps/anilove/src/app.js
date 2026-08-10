require('dotenv').config();
const express = require('express');
const cors = require('cors');
const sequelize = require('./config/database');
const { dbSchema, useSsl } = require('./config/database');
const { requestTimingMiddleware, metricsRouter } = require('./metrics');

require('./models');

const userRoutes = require('./routes/userRoutes');
const animeRoutes = require('./routes/animeRoutes');
const userAnimeListRoutes = require('./routes/userAnimeListRoutes');

const app = express();
app.use(cors());
app.use(express.json());

// Request timing for /animes CRUD (see metrics.js)
app.use(requestTimingMiddleware);

app.get('/health', (_req, res) =>
  res.status(200).json({
    status: 'ok',
    dbSchema,
    ssl: useSsl,
  })
);
app.get('/', (_req, res) => res.send('AniLove API is running'));

app.use('/users', userRoutes);
app.use('/animes', animeRoutes);
app.use('/users/:id/list', userAnimeListRoutes);

app.use(metricsRouter);

async function initDatabase() {
  // Create non-public schema on startup when DB_SCHEMA is set
  if (dbSchema && dbSchema !== 'public') {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(dbSchema)) {
      throw new Error(`Invalid DB_SCHEMA: ${dbSchema}`);
    }
    await sequelize.query(`CREATE SCHEMA IF NOT EXISTS "${dbSchema}"`);
    console.log(`schema ready: ${dbSchema}`);
  }
  await sequelize.sync();
  console.log(`database synced (schema=${dbSchema}, ssl=${useSsl})`);
}

// Lambda freezes the container on return, killing a connection opened at
// module load. The handler awaits this; a failure clears it so the next
// invocation retries.
let dbReady = null;

function ensureDatabase() {
  if (!dbReady) {
    dbReady = initDatabase().catch((err) => {
      console.error('database error:', err);
      dbReady = null;
      throw err;
    });
  }
  return dbReady;
}

// EC2 and ECS: start at boot, log failures, keep serving.
ensureDatabase().catch(() => {});

module.exports = app;
module.exports.ensureDatabase = ensureDatabase;
