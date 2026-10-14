const bcrypt = require('bcryptjs');
const { pool } = require('./db');

// Test accounts documented in the README. Demo data only.
const AGENTS = [
  { email: 'agent1@fieldops.test', name: 'Ada Okafor', password: 'FieldOps#2026' },
  { email: 'agent2@fieldops.test', name: 'Tunde Bello', password: 'FieldOps#2026' },
];

const FIELDS = {
  'POS Deployment': [{ key: 'terminal_serial', label: 'Terminal serial number' }, { key: 'sim_number', label: 'SIM number' }],
  'Customer Verification': [{ key: 'id_number', label: 'ID number sighted' }, { key: 'address_confirmed', label: 'Address confirmed' }],
  'Merchant Onboarding': [{ key: 'business_name', label: 'Registered business name' }],
  'Site Inspection': [{ key: 'condition', label: 'Site condition' }],
  'Product Delivery': [{ key: 'recipient_name', label: 'Recipient name' }],
  'Document Collection': [],
  'Customer Visit': [],
};

const day = 86400000;
// [title, type, customer, location, status, priority, dueInDays, evidenceRequired]
const JOBS = [
  ['Deploy POS at Mama Nkechi Supermarket', 'POS Deployment', 'Mama Nkechi Stores', '12 Allen Avenue, Ikeja, Lagos', 'assigned', 'urgent', 1, 2],
  ['Verify customer address - Chinedu Eze', 'Customer Verification', 'Chinedu Eze', '5 Awolowo Road, Ikoyi, Lagos', 'assigned', 'high', 2, 1],
  ['Onboard Bright Pharmacy', 'Merchant Onboarding', 'Bright Pharmacy Ltd', '33 Herbert Macaulay Way, Yaba, Lagos', 'accepted', 'high', 3, 2],
  ['Quarterly inspection - Lekki depot', 'Site Inspection', 'Peachblossoms Lekki Depot', 'Admiralty Way, Lekki Phase 1, Lagos', 'accepted', 'medium', 5, 3],
  ['Deliver POS terminals to Sunrise Foods', 'Product Delivery', 'Sunrise Foods', '8 Ozumba Mbadiwe, Victoria Island, Lagos', 'in_progress', 'urgent', 0, 1],
  ['Collect KYC documents - Amina Yusuf', 'Document Collection', 'Amina Yusuf', '17 Gimbiya Street, Garki, Abuja', 'in_progress', 'medium', 2, 2],
  ['Follow-up visit - Greenfield Farms', 'Customer Visit', 'Greenfield Farms', 'Km 14 Lagos-Ibadan Expressway', 'in_progress', 'low', 6, 0],
  ['Deploy POS at Royal Salon', 'POS Deployment', 'Royal Salon', '2 Adeola Odeku, Victoria Island, Lagos', 'completed', 'medium', -3, 0],
  ['Verify customer - Ngozi Obi', 'Customer Verification', 'Ngozi Obi', '21 Opebi Road, Ikeja, Lagos', 'completed', 'low', -5, 0],
  ['Onboard Tech Hub Cafe', 'Merchant Onboarding', 'Tech Hub Cafe', '4 Admiralty Way, Lekki, Lagos', 'declined', 'medium', -1, 0],
  ['Inspect Surulere branch', 'Site Inspection', 'Peachblossoms Surulere', '90 Adeniran Ogunsanya, Surulere, Lagos', 'cancelled', 'low', -2, 0],
  ['Deliver documents to Apex Logistics', 'Product Delivery', 'Apex Logistics', '3 Wharf Road, Apapa, Lagos', 'failed', 'high', -4, 0],
];

async function seed() {
  const hash = await bcrypt.hash(AGENTS[0].password, 10);
  for (const [i, a] of AGENTS.entries()) {
    const u = (await pool.query(
      `INSERT INTO users (email, name, password_hash) VALUES ($1,$2,$3)
       ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name RETURNING id`,
      [a.email, a.name, hash],
    )).rows[0];
    if (i > 0) continue; // second agent starts with an empty job list (empty-state testing)
    await pool.query('DELETE FROM jobs WHERE user_id = $1', [u.id]);
    for (const [title, type, customer, location, status, priority, dueIn, evidence] of JOBS) {
      const fields = FIELDS[type];
      const form = status === 'completed' ? Object.fromEntries(fields.map((f) => [f.key, 'Verified'])) : {};
      const j = (await pool.query(
        `INSERT INTO jobs (user_id, title, type, customer_name, customer_phone, location, description, status, priority,
                           due_date, assigned_by, assigned_at, required_fields, form_data, evidence_required, updated_at)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'Ops Control', now() - interval '2 days',$11,$12,$13, now() - ($14 || ' hours')::interval)
         RETURNING id`,
        [u.id, title, type, customer, '+23480' + String(10000000 + i * 1111111 + title.length).slice(0, 8), location,
          `${type} for ${customer}. Follow the standard procedure, confirm details on site and capture the required evidence before completing.`,
          status, priority, new Date(Date.now() + dueIn * day), JSON.stringify(fields), JSON.stringify(form), evidence,
          String(JOBS.findIndex((x) => x[0] === title) * 3)],
      )).rows[0];
      if (status !== 'assigned') {
        const path = { accepted: ['accepted'], in_progress: ['accepted', 'in_progress'], completed: ['accepted', 'in_progress', 'completed'],
          declined: ['declined'], cancelled: ['accepted', 'cancelled'], failed: ['accepted', 'in_progress', 'failed'] }[status];
        let from = 'assigned';
        for (const to of path) {
          const reason = ['declined', 'cancelled', 'failed'].includes(to) ? 'Seeded example' : null;
          await pool.query('INSERT INTO status_events (job_id, from_status, to_status, reason) VALUES ($1,$2,$3,$4)', [j.id, from, to, reason]);
          from = to;
        }
      }
    }
  }
}

async function seedIfEmpty() {
  const { rows } = await pool.query('SELECT 1 FROM users LIMIT 1');
  if (!rows.length) await seed();
}

module.exports = { seed, seedIfEmpty };

if (require.main === module) {
  require('./db').migrate().then(seed).then(() => { console.log('seeded'); return pool.end(); })
    .catch((e) => { console.error(e); process.exit(1); });
}
