import 'package:fieldops/core/app_exception.dart';
import 'package:fieldops/data/api_client.dart';
import 'package:fieldops/data/token_storage.dart';
import 'package:fieldops/features/auth/login_screen.dart';
import 'package:fieldops/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiClient {}

void main() {
  late MockApi api;

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(ProviderScope(
      retry: (_, _) => null,
      overrides: [
        apiClientProvider.overrideWithValue(api),
        tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ));
  }

  setUp(() => api = MockApi());

  testWidgets('blocks empty and malformed input without calling the server', (t) async {
    await pump(t);
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);

    await t.enterText(find.byType(TextFormField).first, 'not-an-email');
    await t.enterText(find.byType(TextFormField).last, 'pw');
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(find.text('Enter a valid email address'), findsOneWidget);
    verifyNever(() => api.login(any(), any()));
  });

  testWidgets('shows the server message when the password is wrong', (t) async {
    when(() => api.login(any(), any())).thenThrow(const AppException(ErrorKind.unauthorized, 'Incorrect email or password'));
    await pump(t);
    await t.enterText(find.byType(TextFormField).first, 'agent1@fieldops.test');
    await t.enterText(find.byType(TextFormField).last, 'wrong');
    await t.tap(find.text('Sign in'));
    await t.pumpAndSettle();
    expect(find.text('Incorrect email or password'), findsOneWidget);
    // The form is usable again for another attempt.
    expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('explains a network failure instead of a generic error', (t) async {
    when(() => api.login(any(), any())).thenThrow(const AppException(ErrorKind.network, 'No internet connection.'));
    await pump(t);
    await t.enterText(find.byType(TextFormField).first, 'agent1@fieldops.test');
    await t.enterText(find.byType(TextFormField).last, 'FieldOps#2026');
    await t.tap(find.text('Sign in'));
    await t.pumpAndSettle();
    expect(find.text('No internet connection.'), findsOneWidget);
  });
}

