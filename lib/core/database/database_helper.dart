import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();

  DatabaseHelper._init() {
    sqfliteFfiInit();
  }

  Database? _currentDb;
  String? _currentDbName;

  Future<String> get _dbDir async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final appPath = join(appDocDir.path, 'GerrymanderX', 'Databases');
    await Directory(appPath).create(recursive: true);
    return appPath;
  }

  /// Opens (and optionally copies from assets) the named database.
  /// Returns the opened Database handle.
  Future<Database> openNamedDatabase(String fileName) async {
    // If we already have this DB open, reuse it.
    if (_currentDbName == fileName && _currentDb != null && _currentDb!.isOpen) {
      return _currentDb!;
    }

    // Close any previously open DB.
    if (_currentDb != null && _currentDb!.isOpen) {
      await _currentDb!.close();
    }

    final dir = await _dbDir;
    final dbPath = join(dir, fileName);
    final file = File(dbPath);

    // Copy from assets on first use.
    if (!await file.exists()) {
      try {
        final byteData = await rootBundle.load('assets/db/$fileName');
        final bytes = byteData.buffer.asUint8List();
        await file.writeAsBytes(bytes, flush: true);
      } catch (e) {
        rethrow;
      }
    }

    final databaseFactory = databaseFactoryFfi;
    _currentDb = await databaseFactory.openDatabase(dbPath);
    _currentDbName = fileName;
    return _currentDb!;
  }

  /// Convenience getter: returns the currently open database.
  /// Throws if nothing has been opened yet.
  Database get currentDb {
    if (_currentDb == null || !_currentDb!.isOpen) {
      throw StateError('No database is currently open. Call openNamedDatabase first.');
    }
    return _currentDb!;
  }

  /// Ensures the default election DB is copied from assets
  /// and returns a list of all .db files in the local directory.
  Future<List<String>> ensureDefaultAndListDatabases() async {
    // Always ensure the default DB has been copied.
    final dir = await _dbDir;
    const defaultDb = '2024-National-President-rr.db';
    final file = File(join(dir, defaultDb));
    if (!await file.exists()) {
      try {
        final byteData = await rootBundle.load('assets/db/$defaultDb');
        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      } catch (_) {
        // Asset might not exist; that's okay.
      }
    }

    final entities = await Directory(dir).list().toList();
    return entities
        .whereType<File>()
        .where((f) => f.path.endsWith('.db'))
        .map((f) => basename(f.path))
        .toList()
      ..sort();
  }
}
