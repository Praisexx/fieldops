import 'package:fieldops/domain/job_status.dart';
import 'package:fieldops/domain/models.dart';
import 'package:fieldops/state/providers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

Job j(Map<String, dynamic> m) => Job.fromJson(m);

void main() {
  final a = j(jobJson(id: 'a', title: 'Deploy POS at Mama Nkechi', status: 'assigned', priority: 'urgent'));
  final b = j(jobJson(id: 'b', title: 'Verify address', status: 'in_progress', priority: 'low'));
  final c = j(jobJson(id: 'c', title: 'Old inspection', status: 'completed', priority: 'urgent', updatedAt: '2026-10-01T10:00:00.000Z'));

  group('JobFilter', () {
    test('empty filter matches everything and is inactive', () {
      const f = JobFilter();
      expect(f.isActive, isFalse);
      expect([a, b, c].where(f.matches), hasLength(3));
    });

    test('search is case-insensitive and covers title, customer and location', () {
      expect(const JobFilter(query: 'mama').matches(a), isTrue);
      expect(const JobFilter(query: 'ALLEN AVENUE').matches(a), isTrue);
      expect(const JobFilter(query: 'zzz').matches(a), isFalse);
    });

    test('status and priority filters combine', () {
      final f = JobFilter(statuses: {JobStatus.assigned, JobStatus.completed}, priority: JobPriority.urgent);
      expect([a, b, c].where(f.matches).map((x) => x.id), ['a', 'c']);
    });
  });

  test('sorting puts open jobs first (most urgent first) and closed jobs last', () {
    final sorted = [c, b, a]..sort(compareJobs);
    expect(sorted.map((x) => x.id), ['a', 'b', 'c']);
  });
}
