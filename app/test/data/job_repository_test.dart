import 'dart:io';

import 'package:fieldops/core/app_exception.dart';
import 'package:fieldops/data/api_client.dart';
import 'package:fieldops/data/job_repository.dart';
import 'package:fieldops/data/local_db.dart';
import 'package:fieldops/domain/job_status.dart';
import 'package:fieldops/domain/models.dart';
import 'package:fieldops/domain/outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fixtures.dart';
import '../support/test_db.dart';

class MockApi extends Mock implements ApiClient {}

const offline = AppException(ErrorKind.network, 'No internet connection.');

void main() {
  late LocalDb db;
  late MockApi api;
  late JobRepository repo;
  late Directory dir;

  setUp(() async {
    db = await openTestDb();
    api = MockApi();
    dir = Directory.systemTemp.createTempSync('fieldops_test');
    repo = JobRepository(api: api, db: db, filesDir: dir);
    // Every write attempt fails as if offline unless a test says otherwise.
    when(() => api.postStatus(any(), status: any(named: 'status'), reason: any(named: 'reason'), clientId: any(named: 'clientId'), occurredAt: any(named: 'occurredAt'))).thenThrow(offline);
    when(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId'))).thenThrow(offline);
    when(() => api.putForm(any(), any())).thenThrow(offline);
  });
  tearDown(() async {
    await repo.sync.flush(); // let fire-and-forget syncs from the test finish before the db closes
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<Job> cached(String status, {Map<String, dynamic> form = const {}, int evidenceRequired = 1}) async {
    await db.upsertJob(jobJson(status: status, formData: form, evidenceRequired: evidenceRequired));
    return (await repo.job('job-1'))!;
  }

  test('refreshAll caches the list and every job detail, so everything is readable offline afterwards', () async {
    when(() => api.listJobs()).thenAnswer((_) async => [jobJson(id: 'a', detail: false), jobJson(id: 'b', detail: false)]);
    when(() => api.getJob(any())).thenAnswer((inv) async => jobJson(id: inv.positionalArguments.first as String, notes: [
          {'id': 'n', 'clientId': null, 'body': 'saved', 'createdAt': '2026-10-14T10:00:00.000Z'}
        ]));
    await repo.refreshAll();

    when(() => api.listJobs()).thenThrow(offline);
    when(() => api.getJob(any())).thenThrow(offline);
    expect((await repo.jobs()).length, 2);
    expect((await repo.job('a'))!.notes.single.body, 'saved');
  });

  test('accepting offline updates the screen immediately and keeps the action queued', () async {
    final job = await cached('assigned');
    await repo.changeStatus(job, JobStatus.accepted);
    await repo.sync.flush();
    expect((await repo.job('job-1'))!.status, JobStatus.accepted);
    final q = await db.outbox();
    expect(q.single.type, OutboxType.status);
    expect(q.single.state, OutboxState.pending);
  });

  test('rejects moves the lifecycle does not allow', () async {
    final job = await cached('assigned');
    expect(() => repo.changeStatus(job, JobStatus.completed), throwsA(isA<AppException>().having((e) => e.kind, 'kind', ErrorKind.conflict)));
  });

  test('declining / cancelling / failing requires a reason', () async {
    final job = await cached('assigned');
    expect(() => repo.changeStatus(job, JobStatus.declined), throwsA(isA<AppException>().having((e) => e.fields.keys, 'fields', contains('reason'))));
    expect(() => repo.changeStatus(job, JobStatus.declined, reason: '  '), throwsA(isA<AppException>()));
    await repo.changeStatus(job, JobStatus.declined, reason: 'Too far');
    expect((await db.outbox()).single.payload['reason'], 'Too far');
  });

  test('cannot complete until required info and evidence are in, even offline', () async {
    final job = await cached('in_progress');
    await expectLater(
      repo.changeStatus(job, JobStatus.completed),
      throwsA(isA<AppException>().having((e) => e.fields.keys, 'fields', containsAll(['terminal_serial', 'evidence']))),
    );
    expect(await db.outbox(), isEmpty, reason: 'nothing queued for a blocked action');
  });

  test('queued form answers and text evidence count toward completion', () async {
    var job = await cached('in_progress');
    await repo.saveForm(job, {'terminal_serial': 'T-1'});
    await repo.addTextEvidence(job, 'Signed by owner');
    job = (await repo.job('job-1'))!;
    expect(job.completionProblems(), isEmpty);
    await repo.changeStatus(job, JobStatus.completed);
    expect((await repo.job('job-1'))!.status, JobStatus.completed);
  });

  test('notes and evidence need an accepted / in-progress job and valid input', () async {
    final assigned = await cached('assigned');
    expect(() => repo.addNote(assigned, 'hi'), throwsA(isA<AppException>().having((e) => e.kind, 'kind', ErrorKind.conflict)));
    final active = await cached('in_progress');
    expect(() => repo.addNote(active, '   '), throwsA(isA<AppException>().having((e) => e.kind, 'kind', ErrorKind.validation)));
    expect(() => repo.addNote(active, 'x' * 2001), throwsA(isA<AppException>()));
  });

  test('files over 10 MB are refused before anything is queued', () async {
    final job = await cached('in_progress');
    final big = File('${dir.path}/big.jpg')..writeAsBytesSync(List.filled(maxEvidenceBytes + 1, 0));
    await expectLater(
      repo.addFileEvidence(job, kind: EvidenceKind.photo, sourcePath: big.path, filename: 'big.jpg', mime: 'image/jpeg'),
      throwsA(isA<AppException>().having((e) => e.kind, 'kind', ErrorKind.tooLarge)),
    );
    expect(await db.outbox(), isEmpty);
  });

  test('a photo is copied into app storage before queuing, and discarding it removes the copy', () async {
    final job = await cached('in_progress');
    final src = File('${dir.path}/pic.jpg')..writeAsBytesSync([1, 2, 3]);
    await repo.addFileEvidence(job, kind: EvidenceKind.photo, sourcePath: src.path, filename: 'pic.jpg', mime: 'image/jpeg');
    final item = (await db.outbox()).single;
    final stored = File(item.payload['path'] as String);
    expect(stored.existsSync(), isTrue);
    expect(stored.path, isNot(src.path));
    await repo.discard(item.id);
    expect(stored.existsSync(), isFalse);
    expect(await db.outbox(), isEmpty);
  });

  test('removing evidence that never uploaded just cancels the queued upload', () async {
    final job = await cached('in_progress');
    await repo.addTextEvidence(job, 'note');
    final withEv = (await repo.job('job-1'))!;
    await repo.deleteEvidence(withEv, withEv.evidence.single);
    expect(await db.outbox(), isEmpty);
    expect((await repo.job('job-1'))!.evidence, isEmpty);
  });

  test('retry makes a failed action eligible again', () async {
    final job = await cached('in_progress');
    await repo.addNote(job, 'x');
    final id = (await db.outbox()).single.id;
    await db.setOutboxState(id, OutboxState.failed, error: 'rejected');
    await repo.retry(id);
    expect((await db.outbox()).single.state, isNot(OutboxState.failed));
  });
}
