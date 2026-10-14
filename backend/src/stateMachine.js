// Job lifecycle. Terminal states (completed/declined/cancelled/failed) have no exits.
const TRANSITIONS = {
  assigned: ['accepted', 'declined'],
  accepted: ['in_progress', 'cancelled'],
  in_progress: ['completed', 'failed'],
  completed: [],
  declined: [],
  cancelled: [],
  failed: [],
};
const NEEDS_REASON = new Set(['declined', 'cancelled', 'failed']);
const STATUSES = Object.keys(TRANSITIONS);

const canTransition = (from, to) => (TRANSITIONS[from] || []).includes(to);

// Returns a map of field -> message; empty when the job may be completed.
function completionProblems(job, evidenceCount) {
  const problems = {};
  for (const f of job.required_fields) {
    const v = job.form_data[f.key];
    if (v === undefined || v === null || String(v).trim() === '') problems[f.key] = `${f.label} is required`;
  }
  if (evidenceCount < job.evidence_required) {
    problems.evidence = `At least ${job.evidence_required} evidence item(s) required (${evidenceCount} submitted)`;
  }
  return problems;
}

module.exports = { TRANSITIONS, NEEDS_REASON, STATUSES, canTransition, completionProblems };
