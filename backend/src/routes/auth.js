const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const { Router } = require('express');
const { z } = require('zod');
const { pool } = require('../db');
const { ApiError, wrap } = require('../errors');
const { signAccess, ACCESS_TTL_SECONDS } = require('../auth');

const r = Router();
const REFRESH_TTL_DAYS = 30;
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
// Compared when the email is unknown so response time doesn't reveal which emails exist.
const DUMMY_HASH = bcrypt.hashSync('dummy', 10);

async function issueTokens(user) {
  const refreshToken = crypto.randomBytes(48).toString('hex');
  await pool.query(
    `INSERT INTO refresh_tokens (token_hash, user_id, expires_at) VALUES ($1,$2, now() + ($3 || ' days')::interval)`,
    [sha(refreshToken), user.id, String(REFRESH_TTL_DAYS)],
  );
  return {
    accessToken: signAccess(user),
    refreshToken,
    expiresIn: ACCESS_TTL_SECONDS,
    user: { id: user.id, name: user.name, email: user.email },
  };
}

const loginBody = z.object({ email: z.string().email(), password: z.string().min(1) });
r.post('/login', wrap(async (req, res) => {
  const { email, password } = loginBody.parse(req.body);
  const { rows } = await pool.query('SELECT * FROM users WHERE email = $1', [email.toLowerCase()]);
  const user = rows[0];
  const ok = await bcrypt.compare(password, user ? user.password_hash : DUMMY_HASH);
  if (!user || !ok) throw new ApiError(401, 'invalid_credentials', 'Incorrect email or password');
  res.json(await issueTokens(user));
}));

const refreshBody = z.object({ refreshToken: z.string().min(1) });
r.post('/refresh', wrap(async (req, res) => {
  const { refreshToken } = refreshBody.parse(req.body);
  // Single-use: delete on read so a stolen token can't be replayed after rotation.
  const { rows } = await pool.query(
    'DELETE FROM refresh_tokens WHERE token_hash = $1 AND expires_at > now() RETURNING user_id',
    [sha(refreshToken)],
  );
  if (!rows[0]) throw new ApiError(401, 'session_expired', 'Session expired, please sign in again');
  const user = (await pool.query('SELECT * FROM users WHERE id = $1', [rows[0].user_id])).rows[0];
  res.json(await issueTokens(user));
}));

r.post('/logout', wrap(async (req, res) => {
  const { refreshToken } = refreshBody.parse(req.body);
  await pool.query('DELETE FROM refresh_tokens WHERE token_hash = $1', [sha(refreshToken)]);
  res.status(204).end();
}));

module.exports = r;
