const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

// Railway's internal Postgres host needs no SSL; public proxy URLs do.
const needsSsl = /proxy\.rlwy\.net|sslmode=require/.test(process.env.DATABASE_URL || '');
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: needsSsl ? { rejectUnauthorized: false } : undefined,
});

const migrate = () => pool.query(fs.readFileSync(path.join(__dirname, '../db/schema.sql'), 'utf8'));

module.exports = { pool, migrate };
