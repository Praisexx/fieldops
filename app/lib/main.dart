import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'data/local_db.dart';
import 'state/providers.dart';

Future<void> main() async {
  // Last line of defence: log unexpected errors instead of crashing, and show a calm fallback for broken widgets.
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) {
      FlutterError.presentError(d);
      debugPrint('Unhandled Flutter error: ${d.exceptionAsString()}');
    };
    ErrorWidget.builder = (details) => Material(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(kDebugMode ? details.exceptionAsString() : 'Something went wrong showing this part of the screen.', textAlign: TextAlign.center),
            ),
          ),
        );

    // Desktop has no native sqflite; use the FFI implementation (lets the app run on a laptop for demos).
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final docs = await getApplicationDocumentsDirectory();
    final db = await LocalDb.open(p.join(docs.path, 'fieldops.db'));
    runApp(ProviderScope(
      // Failures are handled in the UI (retry buttons); don't auto-retry providers in the background.
      retry: (_, _) => null,
      overrides: [
        localDbProvider.overrideWithValue(db),
        filesDirProvider.overrideWithValue(docs),
      ],
      child: const FieldOpsApp(),
    ));
  }, (e, s) => debugPrint('Unhandled error: $e\n$s'));
}
