import 'package:fieldops/data/local_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<LocalDb> openTestDb() async {
  sqfliteFfiInit();
  return LocalDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
}
