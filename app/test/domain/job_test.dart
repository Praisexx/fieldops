import 'package:fieldops/domain/job_status.dart';
import 'package:fieldops/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  group('JobStatus lifecycle', () {
    test('mirrors the server state machine', () {
      expect(JobStatus.assigned.next, [JobStatus.accepted, JobStatus.declined]);
      expect(JobStatus.accepted.next, [JobStatus.inProgress, JobStatus.cancelled]);
      expect(JobStatus.inProgress.next, [JobStatus.completed, JobStatus.failed]);
      for (final s in [JobStatus.completed, JobStatus.declined, JobStatus.cancelled, JobStatus.failed]) {
        expect(s.next, isEmpty, reason: '$s is terminal');
        expect(s.isOpen, isFalse);
      }
    });

    test('only accepted / in-progress jobs are workable', () {
      expect(JobStatus.assigned.isWorkable, isFalse);
      expect(JobStatus.accepted.isWorkable, isTrue);
      expect(JobStatus.inProgress.isWorkable, isTrue);
      expect(JobStatus.completed.isWorkable, isFalse);
    });

    test('declined / cancelled / failed need a reason', () {
      expect(JobStatus.values.where((s) => s.needsReason), {JobStatus.declined, JobStatus.cancelled, JobStatus.failed});
    });

    test('wire names round-trip, unknown falls back safely', () {
      for (final s in JobStatus.values) {
        expect(JobStatus.parse(s.wire), s);
      }
      expect(JobStatus.parse('something_new'), JobStatus.assigned);
    });
  });

  group('Job.fromJson', () {
    test('parses a list item (no detail)', () {
      final j = Job.fromJson(jobJson(detail: false));
      expect(j.hasDetail, isFalse);
      expect(j.notes, isEmpty);
      expect(j.requiredFields.single.label, 'Terminal serial number');
    });

    test('parses nested detail', () {
      final j = Job.fromJson(jobJson(
        status: 'in_progress',
        notes: [{'id': 'n1', 'clientId': 'c1', 'body': 'hi', 'createdAt': '2026-10-14T10:00:00.000Z'}],
        evidence: [{'id': 'e1', 'clientId': null, 'kind': 'photo', 'filename': 'a.jpg', 'mime': 'image/jpeg', 'size': 10, 'text': null, 'createdAt': '2026-10-14T10:00:00.000Z'}],
        history: [{'id': 'h1', 'fromStatus': 'accepted', 'toStatus': 'in_progress', 'reason': null, 'occurredAt': '2026-10-14T10:00:00.000Z'}],
      ));
      expect(j.hasDetail, isTrue);
      expect(j.status, JobStatus.inProgress);
      expect(j.notes.single.body, 'hi');
      expect(j.evidence.single.kind, EvidenceKind.photo);
      expect(j.history.single.to, JobStatus.inProgress);
    });
  });

  group('completionProblems', () {
    test('flags blank required fields and missing evidence', () {
      final j = Job.fromJson(jobJson(formData: {'terminal_serial': '   '}, evidenceRequired: 2));
      final p = j.completionProblems();
      expect(p.keys, containsAll(['terminal_serial', 'evidence']));
    });

    test('is empty when everything is provided', () {
      final j = Job.fromJson(jobJson(
        formData: {'terminal_serial': 'T-1'},
        evidenceRequired: 1,
        evidence: [{'id': 'e1', 'kind': 'text', 'text': 'ok', 'createdAt': '2026-10-14T10:00:00.000Z'}],
      ));
      expect(j.completionProblems(), isEmpty);
    });
  });
}
