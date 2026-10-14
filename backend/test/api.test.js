// Integration tests: need a Postgres in TEST_DATABASE_URL (they reset its tables). Skipped otherwise.
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');

const DB = process.env.TEST_DATABASE_URL;
const skip = DB ? false : 'TEST_DATABASE_URL not set';

test('API', { skip }, async (t) => {
  process.env.DATABASE_URL = DB;
  process.env.JWT_SECRET = 'test-secret';
  const request = require('supertest');
  const app = require('../src/app');
  const { pool, migrate } = require('../src/db');
  const { seed } = require('../src/seed');
  await pool.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public');
  await migrate();
  await seed();
  t.after(() => pool.end());

  const login = (email = 'agent1@fieldops.test', password = 'FieldOps#2026') =>
    request(app).post('/auth/login').send({ email, password });
  const { body: session } = await login();
  const auth = { Authorization: `Bearer ${session.accessToken}` };
  const jobByTitle = async (q) => (await request(app).get('/jobs').query({ q }).set(auth)).body.items[0];

  await t.test('rejects wrong password and unauthenticated access', async () => {
    const bad = await login('agent1@fieldops.test', 'nope');
    assert.strictEqual(bad.status, 401);
    assert.strictEqual(bad.body.error.code, 'invalid_credentials');
    assert.strictEqual((await request(app).get('/jobs')).status, 401);
    assert.strictEqual((await request(app).get('/jobs').set('Authorization', 'Bearer junk')).status, 401);
  });

  await t.test('refresh token rotates and cannot be reused', async () => {
    const first = (await login()).body;
    const ok = await request(app).post('/auth/refresh').send({ refreshToken: first.refreshToken });
    assert.strictEqual(ok.status, 200);
    const replay = await request(app).post('/auth/refresh').send({ refreshToken: first.refreshToken });
    assert.strictEqual(replay.status, 401);
  });

  await t.test('search, filter and empty list', async () => {
    const all = (await request(app).get('/jobs').set(auth)).body;
    assert.ok(all.total >= 10);
    const open = (await request(app).get('/jobs').query({ status: 'assigned,accepted' }).set(auth)).body.items;
    assert.ok(open.length > 0 && open.every((j) => ['assigned', 'accepted'].includes(j.status)));
    assert.strictEqual((await jobByTitle('lekki depot')).title, 'Quarterly inspection - Lekki depot');
    assert.strictEqual((await request(app).get('/jobs').query({ q: '%' }).set(auth)).body.total, 0); // wildcard escaped
    const s2 = (await login('agent2@fieldops.test')).body;
    const none = await request(app).get('/jobs').set('Authorization', `Bearer ${s2.accessToken}`);
    assert.deepStrictEqual(none.body.items, []);
  });

  await t.test('agents cannot see each other\'s jobs', async () => {
    const job = await jobByTitle('Royal Salon');
    const s2 = (await login('agent2@fieldops.test')).body;
    const res = await request(app).get(`/jobs/${job.id}`).set('Authorization', `Bearer ${s2.accessToken}`);
    assert.strictEqual(res.status, 404);
  });

  await t.test('full lifecycle with idempotent offline replay and completion rules', async () => {
    const job = await jobByTitle('Deploy POS at Mama Nkechi'); // assigned, 2 fields, 2 evidence
    const status = (body) => request(app).post(`/jobs/${job.id}/status`).set(auth).send(body);

    assert.strictEqual((await status({ status: 'completed' })).status, 409); // cannot skip stages
    assert.strictEqual((await request(app).post(`/jobs/${job.id}/notes`).set(auth).send({ body: 'early' })).status, 409);
    const cid = crypto.randomUUID();
    assert.strictEqual((await status({ status: 'accepted', clientId: cid })).status, 200);
    assert.strictEqual((await status({ status: 'accepted', clientId: cid })).status, 200); // replay, not 409
    assert.strictEqual((await status({ status: 'in_progress' })).status, 200);

    const nid = crypto.randomUUID();
    const n1 = await request(app).post(`/jobs/${job.id}/notes`).set(auth).send({ body: 'On site', clientId: nid });
    const n2 = await request(app).post(`/jobs/${job.id}/notes`).set(auth).send({ body: 'On site', clientId: nid });
    assert.strictEqual(n1.status, 201);
    assert.strictEqual(n2.status, 200);
    assert.strictEqual(n1.body.id, n2.body.id);
    assert.strictEqual((await request(app).post(`/jobs/${job.id}/notes`).set(auth).send({ body: '  ' })).status, 422);

    const blocked = await status({ status: 'completed' });
    assert.strictEqual(blocked.status, 422);
    assert.ok(blocked.body.error.fields.terminal_serial && blocked.body.error.fields.evidence);

    await request(app).put(`/jobs/${job.id}/form`).set(auth).send({ answers: { terminal_serial: 'T-1', sim_number: 'S-1' } }).expect(200);
    await request(app).post(`/jobs/${job.id}/evidence`).set(auth)
      .field('kind', 'photo').attach('file', Buffer.from('fakejpg'), { filename: 'a.jpg', contentType: 'image/jpeg' }).expect(201);
    const txt = await request(app).post(`/jobs/${job.id}/evidence`).set(auth).send({ kind: 'text', text: 'Signed by owner' });
    assert.strictEqual(txt.status, 201);
    assert.strictEqual((await request(app).post(`/jobs/${job.id}/evidence`).set(auth)
      .field('kind', 'photo').attach('file', Buffer.from('x'), { filename: 'a.exe', contentType: 'application/x-msdownload' })).status, 415);

    assert.strictEqual((await status({ status: 'completed' })).body.status, 'completed');
    const detail = (await request(app).get(`/jobs/${job.id}`).set(auth)).body;
    assert.strictEqual(detail.history.length, 3);
    assert.strictEqual((await status({ status: 'failed', reason: 'x' })).status, 409); // terminal
  });

  await t.test('declining requires a reason', async () => {
    const job = await jobByTitle('Verify customer address');
    const res = await request(app).post(`/jobs/${job.id}/status`).set(auth).send({ status: 'declined' });
    assert.strictEqual(res.status, 422);
    assert.ok(res.body.error.fields.reason);
  });

  await t.test('dashboard counts match', async () => {
    const d = (await request(app).get('/dashboard').set(auth)).body;
    assert.strictEqual(d.summary.total, Object.values(d.counts).reduce((a, b) => a + b, 0));
    assert.ok(d.important.length > 0 && d.recent.length > 0);
  });
});
