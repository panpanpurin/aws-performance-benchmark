// Seed the active DB_SCHEMA up to SEED_ROWS rows. Idempotent.
//   DB_SCHEMA=ec2 node seedDB.js      (run after cleanDB.js)
//
// Without a seed, the fixed page GET /animes returns holds only the rows in
// flight, which is the concurrency-dependent cost the page size removes.
// Not done at app startup: that runs on every Lambda cold start, and cold start
// is a reported metric.

require('dotenv').config();
const sequelize = require('./src/config/database');
const Anime = require('./src/models/Anime');

const SEED_ROWS = Number(process.env.SEED_ROWS || 500);
const BATCH = 100;

// Fixed content, no randomness: every platform must read the same bytes.
const GENRES = [
  ['Action', 'Fantasy'],
  ['Adventure'],
  ['Drama', 'Romance'],
  ['Comedy'],
  ['Sci-Fi', 'Action'],
];

function row(i) {
  return {
    title: `Seed_Anime_${String(i).padStart(5, '0')}`,
    genre: GENRES[i % GENRES.length],
    episodes: 12 + (i % 39),
    note: 1 + (i % 10),
  };
}

(async () => {
  const schema = process.env.DB_SCHEMA || 'public';
  try {
    await sequelize.authenticate();

    const existing = await Anime.count();
    if (existing >= SEED_ROWS) {
      console.log(`[seed-db] schema=${schema} already has ${existing} rows, target ${SEED_ROWS}: nothing to do`);
      process.exit(0);
    }

    const missing = SEED_ROWS - existing;
    console.log(`[seed-db] schema=${schema} has ${existing}, inserting ${missing} to reach ${SEED_ROWS}`);

    for (let start = existing; start < SEED_ROWS; start += BATCH) {
      const size = Math.min(BATCH, SEED_ROWS - start);
      await Anime.bulkCreate(Array.from({ length: size }, (_, k) => row(start + k)));
    }

    console.log(`[seed-db] done, ${await Anime.count()} rows in schema "${schema}"`);
    process.exit(0);
  } catch (err) {
    console.error('[seed-db] failed:', err);
    process.exit(1);
  } finally {
    await sequelize.close();
  }
})();
