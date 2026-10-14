const app = require('./app');
const { migrate } = require('./db');
const { seedIfEmpty } = require('./seed');

(async () => {
  await migrate();
  if (process.env.AUTO_SEED === 'true') await seedIfEmpty();
  const port = process.env.PORT || 3000;
  app.listen(port, () => console.log(`FieldOps API listening on ${port}`));
})().catch((e) => { console.error('Startup failed', e); process.exit(1); });
