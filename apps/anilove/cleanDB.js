// Truncate tables in the active DB_SCHEMA only (safe with shared RDS).
// node cleanDB.js

require('dotenv').config();
const { Sequelize } = require('sequelize');

const SCHEMA = process.env.DB_SCHEMA || 'public';
const PRESERVE_TABLES = new Set(
  (process.env.PRESERVE_TABLES || 'SequelizeMeta')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
);

const useSsl = process.env.DB_SSL !== 'false' && process.env.DB_SSL !== '0';
const rejectUnauthorized =
  process.env.DB_SSL_REJECT_UNAUTHORIZED === 'true' ||
  process.env.DB_SSL_REJECT_UNAUTHORIZED === '1';

function getSequelize() {
  return new Sequelize(
    process.env.DB_NAME,
    process.env.DB_USER,
    process.env.DB_PASSWORD,
    {
      host: process.env.DB_HOST,
      port: Number(process.env.DB_PORT || 5432),
      dialect: 'postgres',
      logging: false,
      dialectOptions: useSsl
        ? { ssl: { require: true, rejectUnauthorized } }
        : {},
    }
  );
}

async function clearDatabase(sequelize, { schema = SCHEMA, preserve = PRESERVE_TABLES } = {}) {
  const t = await sequelize.transaction();
  try {
    const [rows] = await sequelize.query(
      `
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = :schema
        AND table_type = 'BASE TABLE'
      ORDER BY table_name;
      `,
      { replacements: { schema }, transaction: t }
    );

    const targets = rows.map((r) => r.table_name).filter((name) => !preserve.has(name));
    if (targets.length === 0) {
      console.log(`[clear-db] Nothing to truncate in schema "${schema}".`);
      await t.commit();
      return { schema, truncated: [] };
    }

    const fqns = targets.map((n) => `"${schema}"."${n}"`).join(', ');
    console.log(`[clear-db] schema=${schema} truncating: ${targets.join(', ')}`);
    await sequelize.query(`TRUNCATE TABLE ${fqns} RESTART IDENTITY CASCADE;`, { transaction: t });

    await t.commit();
    return { schema, truncated: targets };
  } catch (err) {
    await t.rollback();
    throw err;
  }
}

(async () => {
  const sequelize = getSequelize();
  try {
    await sequelize.authenticate();
    const result = await clearDatabase(sequelize);
    console.log('Database cleared:', result);
    process.exit(0);
  } catch (err) {
    console.error('Error clearing database:', err);
    process.exit(1);
  } finally {
    await sequelize.close();
  }
})();
