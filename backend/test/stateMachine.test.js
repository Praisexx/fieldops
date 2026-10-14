const test = require('node:test');
const assert = require('node:assert');
const { canTransition, completionProblems, TRANSITIONS } = require('../src/stateMachine');

test('allows the happy path and decline/cancel/fail exits', () => {
  assert.ok(canTransition('assigned', 'accepted'));
  assert.ok(canTransition('assigned', 'declined'));
  assert.ok(canTransition('accepted', 'in_progress'));
  assert.ok(canTransition('accepted', 'cancelled'));
  assert.ok(canTransition('in_progress', 'completed'));
  assert.ok(canTransition('in_progress', 'failed'));
});

test('rejects skipping stages and leaving terminal states', () => {
  assert.ok(!canTransition('assigned', 'completed'));
  assert.ok(!canTransition('accepted', 'completed'));
  for (const t of ['completed', 'declined', 'cancelled', 'failed']) assert.deepStrictEqual(TRANSITIONS[t], []);
});

test('completion needs required fields and minimum evidence', () => {
  const job = { required_fields: [{ key: 'serial', label: 'Serial' }], form_data: { serial: '  ' }, evidence_required: 2 };
  const p = completionProblems(job, 1);
  assert.ok(p.serial && p.evidence);
  assert.deepStrictEqual(completionProblems({ ...job, form_data: { serial: 'X1' } }, 2), {});
});
