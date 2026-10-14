import 'package:fieldops/core/app_exception.dart';
import 'package:fieldops/data/api_client.dart';
import 'package:fieldops/data/local_db.dart';
import 'package:fieldops/data/sync_service.dart';
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
  late SyncService sync;

  setUp(() async {
    db = await openTestDb();
    api = MockApi();
    when(() => api.getJob(any())).thenAnswer((_) async => jobJson());
    sync = SyncService(api: api, db: db, afterJobSynced: (id) async => db.upsertJob(await api.getJob(id)));
  });
  tearDown(() => db.close());

  Future<void> note(String body, String clientId) =>
      db.enqueue(jobId: 'job-1', type: OutboxType.note, clientId: clientId, payload: {'body': body});

  void noteOk() => when(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId'))).thenAnswer((_) async {});

  test('sends queued actions in the order they were made and clears them', () async {
    noteOk();
    await note('first', 'c1');
    await note('second', 'c2');
    final r = await sync.flush();
    expect(r.sent, 2);
    expect(await db.outbox(), isEmpty);
    verifyInOrder([
      () => api.postNote('job-1', body: 'first', clientId: 'c1'),
      () => api.postNote('job-1', body: 'second', clientId: 'c2'),
    ]);
  });

  test('offline: stops, keeps everything queued and reports why', () async {
    when(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId'))).thenThrow(offline);
    await note('first', 'c1');
    await note('second', 'c2');
    final r = await sync.flush();
    expect(r.error?.kind, ErrorKind.network);
    final left = await db.outbox();
    expect(left.map((o) => o.state), everyElement(OutboxState.pending));
    expect(left, hasLength(2));
    verify(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId'))).called(1); // did not hammer the second
  });

  test('retry after reconnecting reuses the same clientId, so the server can de-duplicate', () async {
    var calls = 0;
    final seen = <String>[];
    when(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId'))).thenAnswer((inv) async {
      seen.add(inv.namedArguments[#clientId] as String);
      if (++calls == 1) throw offline;
    });
    await note('hello', 'c1');
    await sync.flush();
    expect(await db.outbox(), hasLength(1));
    await sync.flush();
    expect(await db.outbox(), isEmpty);
    expect(seen, ['c1', 'c1']);
  });

  test('a rejected action is marked failed with the reason, and the rest of the queue still syncs', () async {
    when(() => api.postNote(any(), body: 'bad', clientId: any(named: 'clientId')))
        .thenThrow(const AppException(ErrorKind.conflict, 'Job is completed; it is already closed'));
    when(() => api.postNote(any(), body: 'good', clientId: any(named: 'clientId'))).thenAnswer((_) async {});
    await note('bad', 'c1');
    await note('good', 'c2');
    final r = await sync.flush();
    expect((r.sent, r.failed), (1, 1));
    final left = await db.outbox();
    expect(left.single.state, OutboxState.failed);
    expect(left.single.error, contains('already closed'));
  });

  test('failed items are not retried until the user asks', () async {
    when(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId')))
        .thenThrow(const AppException(ErrorKind.validation, 'nope'));
    await note('x', 'c1');
    await sync.flush();
    await sync.flush();
    verify(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId'))).called(1);
  });

  test('a run that died mid-send (row stuck as "syncing") is picked up again', () async {
    noteOk();
    final item = await db.enqueue(jobId: 'job-1', type: OutboxType.note, clientId: 'c1', payload: {'body': 'x'});
    await db.setOutboxState(item.id, OutboxState.syncing);
    expect((await sync.flush()).sent, 1);
  });

  test('removing evidence that is already gone on the server counts as done', () async {
    when(() => api.deleteEvidence(any(), any())).thenThrow(const AppException(ErrorKind.notFound, 'gone'));
    await db.enqueue(jobId: 'job-1', type: OutboxType.evidenceDelete, clientId: 'c1', payload: {'evidenceId': 'e1'});
    final r = await sync.flush();
    expect(r.sent, 1);
    expect(await db.outbox(), isEmpty);
  });

  test('expired session pauses the queue without losing anything', () async {
    when(() => api.postNote(any(), body: any(named: 'body'), clientId: any(named: 'clientId')))
        .thenThrow(const AppException(ErrorKind.sessionExpired, 'expired'));
    await note('keep me', 'c1');
    final r = await sync.flush();
    expect(r.error?.kind, ErrorKind.sessionExpired);
    expect((await db.outbox()).single.state, OutboxState.pending);
  });

  test('refreshes the job from the server once its changes landed', () async {
    noteOk();
    await note('x', 'c1');
    await sync.flush();
    verify(() => api.getJob('job-1')).called(1);
    expect(await db.job('job-1'), isNotNull);
  });
}
