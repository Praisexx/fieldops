import 'dart:io';

import 'package:fieldops/data/api_client.dart';
import 'package:fieldops/data/token_storage.dart';
import 'package:fieldops/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/test_db.dart';

class MockApi extends Mock implements ApiClient {}

Session session(String id) => Session(accessToken: 'a', refreshToken: 'r', userId: id, name: 'N $id', email: '$id@x.test');

void main() {
  test('signing in as another account starts a fresh sync (no state left over from the previous session)', () async {
    final api = MockApi();
    when(() => api.listJobs()).thenAnswer((_) async => []);
    when(() => api.logout(any())).thenAnswer((_) async {});
    final db = await openTestDb();
    final dir = Directory.systemTemp.createTempSync('fieldops_session');
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      localDbProvider.overrideWithValue(db),
      filesDirProvider.overrideWithValue(dir),
      tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
      onlineProvider.overrideWith((ref) => Stream.value(true)),
    ]);
    addTearDown(() async {
      c.dispose();
      await db.close();
      dir.deleteSync(recursive: true);
    });
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    await c.read(authProvider.future);

    when(() => api.login(any(), any())).thenAnswer((_) async => session('agent2'));
    await c.read(authProvider.notifier).login('agent2@x.test', 'pw');
    c.read(tabIndexProvider.notifier).set(1);
    c.read(syncProvider); // what HomeShell does once signed in
    await settle();
    verify(() => api.listJobs()).called(1);
    expect(c.read(syncProvider).loadedOnce, isTrue);

    await c.read(authProvider.notifier).logout();

    when(() => api.login(any(), any())).thenAnswer((_) async => session('agent1'));
    await c.read(authProvider.notifier).login('agent1@x.test', 'pw');
    expect(c.read(tabIndexProvider), 0, reason: 'lands on the dashboard, not the previous tab');
    expect(c.read(syncProvider).loadedOnce, isFalse, reason: 'a new session has not loaded anything yet');
    await settle();
    verify(() => api.listJobs()).called(1); // a second fetch for the new login
  });
}
