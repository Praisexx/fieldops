const express = require('express');
const helmet = require('helmet');
const multer = require('multer');
const { ZodError } = require('zod');
const { pool } = require('./db');
const { ApiError } = require('./errors');

const app = express();
app.use(helmet());
app.use(express.json({ limit: '100kb' }));

app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok' });
  } catch {
    res.status(503).json({ status: 'db_unavailable' });
  }
});

app.use('/auth', require('./routes/auth'));
app.use('/', require('./routes/jobs'));

app.use((_req, _res, next) => next(new ApiError(404, 'not_found', 'Route not found')));

// All errors leave in one shape: { error: { code, message, fields? } }
// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  let e = err;
  if (err instanceof ZodError) {
    const fields = {};
    err.issues.forEach((i) => { fields[i.path.join('.') || '_'] = i.message; });
    e = new ApiError(422, 'validation_error', 'Invalid input', fields);
  } else if (err instanceof multer.MulterError) {
    e = new ApiError(err.code === 'LIMIT_FILE_SIZE' ? 413 : 400, 'upload_error', err.code === 'LIMIT_FILE_SIZE' ? 'File too large (max 10MB)' : err.message);
  } else if (err.type === 'entity.parse.failed') {
    e = new ApiError(400, 'bad_json', 'Malformed JSON body');
  } else if (!(err instanceof ApiError)) {
    console.error(err);
    e = new ApiError(500, 'internal_error', 'Something went wrong');
  }
  res.status(e.status).json({ error: { code: e.code, message: e.message, ...(e.fields && { fields: e.fields }) } });
});

module.exports = app;
