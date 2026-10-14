import 'package:fieldops/domain/job_status.dart';
import 'package:fieldops/domain/models.dart';
import 'package:fieldops/domain/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

OutboxItem item(int id, OutboxType type, Map<String, dynamic> payload, {OutboxState state = OutboxState.pending, String? clientId, String jobId = 'job-1'}) =>
    OutboxItem(id: id, jobId: jobId, type: type, clientId: clientId ?? 'c$id', payload: payload, state: state, createdAt: DateTime.utc(2026, 10, 14, 12), error: state == OutboxState.failed ? 'rejected' : null);

void main() {
  final base = Job.fromJson(jobJson(status: 'accepted'));

  test('queued status changes show immediately and stack in order', () {
    final j = applyOutbox(base, [
      item(1, OutboxType.status, {'status': 'in_progress', 'occurredAt': '2026-10-14T12:00:00Z'}),
    ]);
    expect(j.status, JobStatus.inProgress);
    expect(j.history.single.pending, isTrue);
    expect(j.history.single.from, JobStatus.accepted);
  });

  test('queued notes, evidence and form answers are merged in', () {
    final j = applyOutbox(base, [
      item(1, OutboxType.note, {'body': 'on site'}),
      item(2, OutboxType.evidence, {'kind': 'photo', 'filename': 'a.jpg', 'mime': 'image/jpeg', 'size': 5, 'path': '/x'}, state: OutboxState.syncing),
      item(3, OutboxType.form, {'answers': {'terminal_serial': 'T-9'}}),
    ]);
    expect(j.notes.single.sync, SyncState.pending);
    expect(j.evidence.single.sync, SyncState.syncing);
    expect(j.formData['terminal_serial'], 'T-9');
    expect(j.completionProblems(), isEmpty, reason: 'pending work counts toward completion while offline');
  });

  test('does not duplicate a note the server already has (lost response, replayed later)', () {
    final withNote = Job.fromJson(jobJson(status: 'accepted', notes: [
      {'id': 'srv', 'clientId': 'c1', 'body': 'on site', 'createdAt': '2026-10-14T12:00:00.000Z'},
    ]));
    final j = applyOutbox(withNote, [item(1, OutboxType.note, {'body': 'on site'}, clientId: 'c1')]);
    expect(j.notes, hasLength(1));
  });

  test('failed status / form actions are not applied; failed notes stay visible as failed', () {
    final j = applyOutbox(base, [
      item(1, OutboxType.status, {'status': 'in_progress', 'occurredAt': '2026-10-14T12:00:00Z'}, state: OutboxState.failed),
      item(2, OutboxType.form, {'answers': {'terminal_serial': 'X'}}, state: OutboxState.failed),
      item(3, OutboxType.note, {'body': 'keep me'}, state: OutboxState.failed),
    ]);
    expect(j.status, JobStatus.accepted);
    expect(j.formData, isEmpty);
    expect(j.notes.single.sync, SyncState.failed);
  });

  test('queued evidence deletion hides the item', () {
    final withEv = Job.fromJson(jobJson(status: 'accepted', evidence: [
      {'id': 'e1', 'kind': 'text', 'text': 'x', 'createdAt': '2026-10-14T10:00:00.000Z'},
    ]));
    final j = applyOutbox(withEv, [item(1, OutboxType.evidenceDelete, {'evidenceId': 'e1'})]);
    expect(j.evidence, isEmpty);
  });

  test('ignores actions for other jobs', () {
    final j = applyOutbox(base, [item(1, OutboxType.note, {'body': 'x'}, jobId: 'other')]);
    expect(j.notes, isEmpty);
  });
}
