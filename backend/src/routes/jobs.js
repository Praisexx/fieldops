const { Router } = require('express');
const multer = require('multer');
const { z } = require('zod');
const { pool } = require('../db');
const { ApiError, wrap } = require('../errors');
const { requireAuth } = require('../auth');
const sm = require('../stateMachine');

const r = Router();
r.use(requireAuth);

const MAX_FILE_BYTES = 10 * 1024 * 1024;
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_FILE_BYTES, files: 1 } });
const DOC_MIMES = new Set([
  'application/pdf', 'text/plain',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
]);
const WRITABLE = new Set(['accepted', 'in_progress']);

const uuid = z.string().uuid();
const clientId = z.string().uuid().optional();

const jobDto = (j) => ({
  id: j.id, title: j.title, type: j.type, customerName: j.customer_name, customerPhone: j.customer_phone,
  location: j.location, description: j.description, status: j.status, priority: j.priority,
  dueDate: j.due_date, assignedBy: j.assigned_by, assignedAt: j.assigned_at,
  requiredFields: j.required_fields, formData: j.form_data, evidenceRequired: j.evidence_required,
  updatedAt: j.updated_at,
});
const noteDto = (n) => ({ id: n.id, clientId: n.client_id, body: n.body, createdAt: n.created_at });
const evidenceDto = (e) => ({
  id: e.id, clientId: e.client_id, kind: e.kind, filename: e.filename, mime: e.mime, size: e.size,
  text: e.text_body, createdAt: e.created_at,
});
const eventDto = (e) => ({
  id: e.id, fromStatus: e.from_status, toStatus: e.to_status, reason: e.reason, occurredAt: e.occurred_at,
});

// Scoped to the caller so another agent's job id looks like a 404, not a 403.
async function loadJob(req, db = pool, lock = false) {
  if (!uuid.safeParse(req.params.id).success) throw new ApiError(404, 'not_found', 'Job not found');
  const { rows } = await db.query(
    `SELECT * FROM jobs WHERE id = $1 AND user_id = $2 ${lock ? 'FOR UPDATE' : ''}`,
    [req.params.id, req.userId],
  );
  if (!rows[0]) throw new ApiError(404, 'not_found', 'Job not found');
  return rows[0];
}
const touch = (db, jobId) => db.query('UPDATE jobs SET updated_at = now() WHERE id = $1', [jobId]);
function requireWritable(job) {
  if (!WRITABLE.has(job.status)) {
    throw new ApiError(409, 'job_not_active', `Job is ${job.status}; accept it first or it is already closed`);
  }
}

// ---- list / dashboard / detail ----
const listQuery = z.object({
  status: z.string().optional(),
  priority: z.enum(['low', 'medium', 'high', 'urgent']).optional(),
  q: z.string().trim().max(100).optional(),
  updatedSince: z.string().datetime().optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});
r.get('/jobs', wrap(async (req, res) => {
  const f = listQuery.parse(req.query);
  const where = ['user_id = $1'];
  const args = [req.userId];
  const add = (sql, v) => { args.push(v); where.push(sql.replace('?', `$${args.length}`)); };
  if (f.status) {
    const list = f.status.split(',');
    if (!list.every((s) => sm.STATUSES.includes(s))) throw new ApiError(400, 'validation_error', 'Unknown status filter');
    add('status = ANY(?)', list);
  }
  if (f.priority) add('priority = ?', f.priority);
  if (f.updatedSince) add('updated_at > ?', f.updatedSince);
  if (f.q) {
    args.push(`%${f.q.replace(/[\\%_]/g, '\\$&')}%`);
    const p = `$${args.length}`;
    where.push(`(title ILIKE ${p} OR customer_name ILIKE ${p} OR location ILIKE ${p} OR description ILIKE ${p})`);
  }
  const sql = `FROM jobs WHERE ${where.join(' AND ')}`;
  const total = (await pool.query(`SELECT count(*)::int AS n ${sql}`, args)).rows[0].n;
  const { rows } = await pool.query(
    `SELECT * ${sql} ORDER BY updated_at DESC LIMIT ${f.limit} OFFSET ${f.offset}`, args,
  );
  res.json({ items: rows.map(jobDto), total });
}));

r.get('/dashboard', wrap(async (req, res) => {
  const counts = Object.fromEntries(sm.STATUSES.map((s) => [s, 0]));
  (await pool.query('SELECT status, count(*)::int AS n FROM jobs WHERE user_id = $1 GROUP BY status', [req.userId]))
    .rows.forEach((x) => { counts[x.status] = x.n; });
  const open = "status IN ('assigned','accepted','in_progress')";
  const important = (await pool.query(
    `SELECT * FROM jobs WHERE user_id = $1 AND ${open}
     ORDER BY array_position(ARRAY['urgent','high','medium','low'], priority), due_date NULLS LAST LIMIT 5`,
    [req.userId],
  )).rows;
  const recent = (await pool.query(
    'SELECT * FROM jobs WHERE user_id = $1 ORDER BY updated_at DESC LIMIT 5', [req.userId],
  )).rows;
  res.json({
    counts,
    summary: {
      total: Object.values(counts).reduce((a, b) => a + b, 0),
      pending: counts.assigned + counts.accepted, // not started yet
      inProgress: counts.in_progress,
      completed: counts.completed,
    },
    important: important.map(jobDto),
    recent: recent.map(jobDto),
  });
}));

r.get('/jobs/:id', wrap(async (req, res) => {
  const job = await loadJob(req);
  const [notes, evidence, events] = await Promise.all([
    pool.query('SELECT * FROM job_notes WHERE job_id = $1 ORDER BY created_at', [job.id]),
    pool.query('SELECT id, client_id, kind, filename, mime, size, text_body, created_at FROM job_evidence WHERE job_id = $1 ORDER BY created_at', [job.id]),
    pool.query('SELECT * FROM status_events WHERE job_id = $1 ORDER BY occurred_at', [job.id]),
  ]);
  res.json({
    ...jobDto(job),
    allowedTransitions: sm.TRANSITIONS[job.status],
    notes: notes.rows.map(noteDto),
    evidence: evidence.rows.map(evidenceDto),
    history: events.rows.map(eventDto),
  });
}));

// ---- status ----
const statusBody = z.object({
  status: z.enum(sm.STATUSES),
  reason: z.string().trim().max(500).optional(),
  clientId,
  occurredAt: z.string().datetime().optional(),
});
r.post('/jobs/:id/status', wrap(async (req, res) => {
  const body = statusBody.parse(req.body);
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    const job = await loadJob(req, db, true);
    if (body.clientId) {
      const dup = await db.query('SELECT 1 FROM status_events WHERE client_id = $1 AND job_id = $2', [body.clientId, job.id]);
      if (dup.rowCount) { await db.query('COMMIT'); return res.json(jobDto(job)); } // replayed offline action
    }
    if (!sm.canTransition(job.status, body.status)) {
      throw new ApiError(409, 'invalid_transition', `Cannot move a ${job.status} job to ${body.status}`);
    }
    if (sm.NEEDS_REASON.has(body.status) && !body.reason) {
      throw new ApiError(422, 'validation_error', 'A reason is required', { reason: 'Reason is required' });
    }
    if (body.status === 'completed') {
      const n = (await db.query('SELECT count(*)::int AS n FROM job_evidence WHERE job_id = $1', [job.id])).rows[0].n;
      const problems = sm.completionProblems(job, n);
      if (Object.keys(problems).length) throw new ApiError(422, 'incomplete_job', 'Job cannot be completed yet', problems);
    }
    await db.query(
      'INSERT INTO status_events (job_id, client_id, from_status, to_status, reason, occurred_at) VALUES ($1,$2,$3,$4,$5, COALESCE($6, now()))',
      [job.id, body.clientId ?? null, job.status, body.status, body.reason ?? null, body.occurredAt ?? null],
    );
    const { rows } = await db.query('UPDATE jobs SET status = $2, updated_at = now() WHERE id = $1 RETURNING *', [job.id, body.status]);
    await db.query('COMMIT');
    res.json(jobDto(rows[0]));
  } catch (e) {
    await db.query('ROLLBACK');
    throw e;
  } finally {
    db.release();
  }
}));

// ---- form (required information) ----
const formBody = z.object({ answers: z.record(z.union([z.string().max(1000), z.number(), z.boolean()])) });
r.put('/jobs/:id/form', wrap(async (req, res) => {
  const { answers } = formBody.parse(req.body);
  const job = await loadJob(req);
  requireWritable(job);
  const known = new Set(job.required_fields.map((f) => f.key));
  const unknown = Object.keys(answers).filter((k) => !known.has(k));
  if (unknown.length) {
    throw new ApiError(422, 'validation_error', 'Unknown field(s)', Object.fromEntries(unknown.map((k) => [k, 'Unknown field'])));
  }
  const { rows } = await pool.query(
    'UPDATE jobs SET form_data = form_data || $2::jsonb, updated_at = now() WHERE id = $1 RETURNING *',
    [job.id, JSON.stringify(answers)],
  );
  res.json(jobDto(rows[0]));
}));

// ---- notes ----
const noteBody = z.object({ body: z.string().trim().min(1, 'Note cannot be empty').max(2000), clientId });
r.post('/jobs/:id/notes', wrap(async (req, res) => {
  const b = noteBody.parse(req.body);
  const job = await loadJob(req);
  requireWritable(job);
  const ins = await pool.query(
    'INSERT INTO job_notes (job_id, client_id, body) VALUES ($1,$2,$3) ON CONFLICT (client_id) DO NOTHING RETURNING *',
    [job.id, b.clientId ?? null, b.body],
  );
  if (ins.rows[0]) {
    await touch(pool, job.id);
    return res.status(201).json(noteDto(ins.rows[0]));
  }
  const existing = await pool.query('SELECT * FROM job_notes WHERE client_id = $1 AND job_id = $2', [b.clientId, job.id]);
  if (!existing.rows[0]) throw new ApiError(409, 'client_id_conflict', 'clientId already used');
  res.json(noteDto(existing.rows[0])); // replayed offline action
}));

// ---- evidence ----
const evidenceBody = z.object({ kind: z.enum(['photo', 'document', 'text']), text: z.string().trim().max(4000).optional(), clientId });
r.post('/jobs/:id/evidence', upload.single('file'), wrap(async (req, res) => {
  const b = evidenceBody.parse(req.body);
  const job = await loadJob(req);
  requireWritable(job);
  const f = req.file;
  if (b.kind === 'text') {
    if (!b.text) throw new ApiError(422, 'validation_error', 'Text is required', { text: 'Text is required' });
  } else {
    if (!f) throw new ApiError(422, 'validation_error', 'A file is required', { file: 'File is required' });
    const okMime = b.kind === 'photo' ? /^image\/(jpeg|png|webp|heic)$/.test(f.mimetype) : DOC_MIMES.has(f.mimetype);
    if (!okMime) throw new ApiError(415, 'unsupported_file', `Unsupported file type: ${f.mimetype}`);
  }
  const ins = await pool.query(
    `INSERT INTO job_evidence (job_id, client_id, kind, filename, mime, size, text_body, data)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT (client_id) DO NOTHING
     RETURNING id, client_id, kind, filename, mime, size, text_body, created_at`,
    [job.id, b.clientId ?? null, b.kind, f?.originalname ?? null, f?.mimetype ?? null, f?.size ?? null, b.text ?? null, f?.buffer ?? null],
  );
  if (ins.rows[0]) {
    await touch(pool, job.id);
    return res.status(201).json(evidenceDto(ins.rows[0]));
  }
  const existing = await pool.query(
    'SELECT id, client_id, kind, filename, mime, size, text_body, created_at FROM job_evidence WHERE client_id = $1 AND job_id = $2',
    [b.clientId, job.id],
  );
  if (!existing.rows[0]) throw new ApiError(409, 'client_id_conflict', 'clientId already used');
  res.json(evidenceDto(existing.rows[0]));
}));

r.get('/jobs/:id/evidence/:eid/file', wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!uuid.safeParse(req.params.eid).success) throw new ApiError(404, 'not_found', 'Evidence not found');
  const { rows } = await pool.query('SELECT * FROM job_evidence WHERE id = $1 AND job_id = $2 AND data IS NOT NULL', [req.params.eid, job.id]);
  if (!rows[0]) throw new ApiError(404, 'not_found', 'Evidence not found');
  res.set({
    'Content-Type': rows[0].mime,
    'X-Content-Type-Options': 'nosniff',
    'Content-Disposition': `inline; filename="${encodeURIComponent(rows[0].filename || 'file')}"`,
  }).send(rows[0].data);
}));

r.delete('/jobs/:id/evidence/:eid', wrap(async (req, res) => {
  const job = await loadJob(req);
  requireWritable(job);
  if (!uuid.safeParse(req.params.eid).success) throw new ApiError(404, 'not_found', 'Evidence not found');
  const del = await pool.query('DELETE FROM job_evidence WHERE id = $1 AND job_id = $2', [req.params.eid, job.id]);
  if (!del.rowCount) throw new ApiError(404, 'not_found', 'Evidence not found');
  await touch(pool, job.id);
  res.status(204).end();
}));

module.exports = r;
