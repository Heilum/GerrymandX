import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();

  DatabaseHelper._init() {
    sqfliteFfiInit();
  }

  String? _currentElectionName;
  Database? _nationalDb;
  final Map<String, Database> _stateDbs = {};

  Future<String> get dbDir async => _dbDir;

  Future<String> get _dbDir async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final appPath = join(appDocDir.path, 'GerrymanderX', 'Databases');
    await Directory(appPath).create(recursive: true);
    return appPath;
  }

  /// Clears sandbox databases directory.
  Future<void> clearSandboxData() async {
    final dir = await _dbDir;
    final directory = Directory(dir);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
      await directory.create(recursive: true);
    }
  }

  /// Deletes a specific election folder in the sandbox.
  Future<void> deleteElectionFolder(String electionName) async {
    if (_currentElectionName == electionName) {
      await closeCurrentElection();
    }
    final dir = await _dbDir;
    final folder = Directory(join(dir, electionName));
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }
  }

  /// Ensures assets are copied to sandbox and returns all available election folder names.
  Future<List<String>> ensureDefaultAndListDatabases() async {
    final dir = await _dbDir;
    await _copyAssetsIfNeeded();

    final entities = await Directory(dir).list().toList();
    final elections = <String>[];

    for (final entity in entities) {
      if (entity is Directory) {
        final electionName = basename(entity.path);
        final nationalDbFile = File(join(entity.path, 'National.db'));
        if (await nationalDbFile.exists()) {
          elections.add(electionName);
        }
      }
    }

    elections.sort();
    return elections;
  }

  /// Fetches state info (id, name, db_name) from National.db of a given election folder.
  Future<List<Map<String, String>>> getStatesInfoForElection(String electionName) async {
    final dir = await _dbDir;
    final dbPath = join(dir, electionName, 'National.db');
    final file = File(dbPath);
    if (!await file.exists()) {
      await _copyAssetsIfNeeded();
    }
    if (!await file.exists()) return [];

    final databaseFactory = databaseFactoryFfi;
    final db = await databaseFactory.openDatabase(dbPath, options: OpenDatabaseOptions(readOnly: true));
    try {
      final rows = await db.query('states', columns: ['id', 'name', 'db_name']);
      return rows.map((r) => {
        'id': (r['id'] ?? '').toString(),
        'name': (r['name'] ?? '').toString(),
        'db_name': (r['db_name'] ?? '').toString(),
      }).toList();
    } catch (e) {
      debugPrint('Error reading states info for election $electionName: $e');
      return [];
    } finally {
      await db.close();
    }
  }

  Future<void> _copyAssetsIfNeeded() async {
    final dir = await _dbDir;
    try {
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestJson);

      for (final assetPath in manifestMap.keys) {
        if (assetPath.startsWith('assets/db/')) {
          final relativePath = assetPath.substring('assets/db/'.length);
          if (relativePath.isEmpty || relativePath.endsWith('/')) continue;

          final targetPath = join(dir, relativePath);
          final targetFile = File(targetPath);

          if (!await targetFile.exists()) {
            await targetFile.parent.create(recursive: true);
            final byteData = await rootBundle.load(assetPath);
            await targetFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
          }
        }
      }
    } catch (e) {
      debugPrint('Error copying assets: $e');
    }
  }

  /// Opens National.db for an election folder (e.g. 2024-National-President).
  Future<Database> openElection(String electionName) async {
    if (_currentElectionName == electionName && _nationalDb != null && _nationalDb!.isOpen) {
      return _nationalDb!;
    }

    await closeCurrentElection();

    final dir = await _dbDir;
    final nationalDbPath = join(dir, electionName, 'National.db');
    final file = File(nationalDbPath);

    if (!await file.exists()) {
      await _copyAssetsIfNeeded();
    }

    final databaseFactory = databaseFactoryFfi;
    _nationalDb = await databaseFactory.openDatabase(nationalDbPath);
    _currentElectionName = electionName;
    return _nationalDb!;
  }

  /// Opens or retrieves a cached state database (e.g. TX.db) within the current election folder.
  Future<Database> getStateDb(String dbName) async {
    if (_currentElectionName == null) {
      throw StateError('No election is currently open. Call openElection first.');
    }

    if (_stateDbs.containsKey(dbName) && _stateDbs[dbName]!.isOpen) {
      return _stateDbs[dbName]!;
    }

    final dir = await _dbDir;
    final stateDbPath = join(dir, _currentElectionName!, dbName);
    final databaseFactory = databaseFactoryFfi;
    final db = await databaseFactory.openDatabase(stateDbPath);
    _stateDbs[dbName] = db;
    return db;
  }

  Database get nationalDb {
    if (_nationalDb == null || !_nationalDb!.isOpen) {
      throw StateError('No election database is currently open. Call openElection first.');
    }
    return _nationalDb!;
  }

  Future<void> closeCurrentElection() async {
    for (final db in _stateDbs.values) {
      if (db.isOpen) {
        await db.close();
      }
    }
    _stateDbs.clear();

    if (_nationalDb != null && _nationalDb!.isOpen) {
      await _nationalDb!.close();
      _nationalDb = null;
    }
    _currentElectionName = null;
  }
}
