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

  /// State databases from other elections, opened read-only for the comparison
  /// fill modes. Keyed by `<electionName>/<dbName>`.
  final Map<String, Database> _comparisonDbs = {};

  Future<String> get dbDir async => _dbDir;

  Future<String> get _dbDir async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final appPath = join(appDocDir.path, 'GerrymanderX', 'Databases');
    await Directory(appPath).create(recursive: true);
    return appPath;
  }

  /// The app's own store for user-made custom layers. Lives next to (not
  /// inside) the election databases folder, so re-downloading or clearing
  /// elections never touches it.
  Future<String> get customLayerDbPath async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final dir = Directory(join(appDocDir.path, 'GerrymanderX'));
    await dir.create(recursive: true);
    return join(dir.path, 'custom_layers.db');
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

  /// Name of the per-election manifest describing candidates, parties and dbs.
  static const metaFileName = 'meta.json';

  /// Ensures assets are copied to sandbox and returns all available election folder names.
  ///
  /// A folder counts as an election as soon as it has a [metaFileName]; the
  /// individual databases (including National.db) may be downloaded later.
  Future<List<String>> ensureDefaultAndListDatabases() async {
    final dir = await _dbDir;
    await _copyAssetsIfNeeded();

    final entities = await Directory(dir).list().toList();
    final elections = <String>[];

    for (final entity in entities) {
      if (entity is Directory) {
        final electionName = basename(entity.path);
        if (await File(join(entity.path, metaFileName)).exists()) {
          elections.add(electionName);
          continue;
        }
        // Folders created before meta.json existed.
        final nationalDbFile = File(join(entity.path, 'National.db'));
        final nationalTmpFile = File(join(entity.path, 'National.db.tmp'));
        if (await nationalDbFile.exists() && !await nationalTmpFile.exists()) {
          elections.add(electionName);
        }
      }
    }

    elections.sort();
    return elections;
  }

  /// Returns the downloaded `*.db` file names for an election folder, skipping
  /// files whose download is still in progress.
  Future<List<String>> getDownloadedDbNames(String electionName) async {
    final dir = await _dbDir;
    final folder = Directory(join(dir, electionName));
    if (!await folder.exists()) return [];
    final names = <String>[];
    await for (final entity in folder.list()) {
      if (entity is File && entity.path.endsWith('.db')) {
        if (await File('${entity.path}.tmp').exists()) continue;
        names.add(basename(entity.path));
      }
    }
    names.sort();
    return names;
  }

  Future<bool> hasNationalDb(String electionName) async {
    final dir = await _dbDir;
    final path = join(dir, electionName, 'National.db');
    return await File(path).exists() && !await File('$path.tmp').exists();
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

  /// The `meta` table of a state database in an election folder — state
  /// name, code and year for the year-folder databases; empty for a legacy
  /// database, which has no such table.
  Future<Map<String, String>> readStateDbMeta(
    String electionName,
    String dbName,
  ) async {
    final dir = await _dbDir;
    final path = join(dir, electionName, dbName);
    if (!await File(path).exists()) return const {};
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      final rows = await db.query('meta');
      return {
        for (final r in rows)
          if (r['key'] != null) r['key'].toString(): (r['value'] ?? '').toString(),
      };
    } catch (_) {
      return const {};
    } finally {
      await db.close();
    }
  }

  Future<void> _copyAssetsIfNeeded() async {
    final dir = await _dbDir;
    try {
      final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assetPaths = assetManifest.listAssets();

      for (final assetPath in assetPaths) {
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

  /// Opens an election folder, and National.db with it when that file is
  /// present. An election whose National.db has not been downloaded yet is
  /// still usable — only the national view is unavailable.
  Future<Database?> openElection(String electionName) async {
    if (_currentElectionName == electionName) {
      if (_nationalDb != null && _nationalDb!.isOpen) return _nationalDb;
      if (!await hasNationalDb(electionName)) return null;
    }

    await closeCurrentElection();
    _currentElectionName = electionName;

    final dir = await _dbDir;
    final nationalDbPath = join(dir, electionName, 'National.db');
    final file = File(nationalDbPath);

    if (!await file.exists()) {
      await _copyAssetsIfNeeded();
    }
    if (!await file.exists()) {
      debugPrint('National.db not downloaded for $electionName');
      return null;
    }

    final databaseFactory = databaseFactoryFfi;
    _nationalDb = await databaseFactory.openDatabase(nationalDbPath);
    return _nationalDb;
  }

  bool get isNationalDbOpen => _nationalDb != null && _nationalDb!.isOpen;

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

  /// Opens a state database belonging to an election *other* than the open one,
  /// for cross-election comparison.
  ///
  /// Kept out of [_stateDbs] so that switching elections does not close it and
  /// it does not shadow the current election's database of the same name. Only
  /// one is held open at a time — comparisons look at a single other election.
  Future<Database?> getComparisonStateDb(
    String electionName,
    String dbName,
  ) async {
    final key = join(electionName, dbName);
    final cached = _comparisonDbs[key];
    if (cached != null && cached.isOpen) return cached;

    final dir = await _dbDir;
    final path = join(dir, electionName, dbName);
    if (!await File(path).exists()) return null;

    await closeComparisonDbs();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    _comparisonDbs[key] = db;
    return db;
  }

  Future<void> closeComparisonDbs() async {
    for (final db in _comparisonDbs.values) {
      if (db.isOpen) await db.close();
    }
    _comparisonDbs.clear();
  }

  Database get nationalDb {
    if (_nationalDb == null || !_nationalDb!.isOpen) {
      throw StateError('No election database is currently open. Call openElection first.');
    }
    return _nationalDb!;
  }

  Future<void> closeCurrentElection() async {
    await closeComparisonDbs();
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
