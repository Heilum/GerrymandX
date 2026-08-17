import 'dart:ui';

import 'package:gerrymanderx/models/custom_layer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Persistence for [CustomLayer]s in a single SQLite file of the app's own
/// (kept apart from the downloaded election databases, which are replaced
/// wholesale on re-download).
///
/// Every mutation is a single transaction, so "edit = save" is one call.
class CustomLayerRepository {
  CustomLayerRepository._(this._db);

  final Database _db;

  static const _schema = [
    '''
    CREATE TABLE IF NOT EXISTS custom_layers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      election TEXT NOT NULL,
      db_name TEXT NOT NULL,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )''',
    '''
    CREATE INDEX IF NOT EXISTS idx_custom_layers_scope
      ON custom_layers(election, db_name)''',
    '''
    CREATE TABLE IF NOT EXISTS group_cells (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      layer_id INTEGER NOT NULL REFERENCES custom_layers(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      color INTEGER NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0
    )''',
    '''
    CREATE TABLE IF NOT EXISTS group_cell_precincts (
      group_id INTEGER NOT NULL REFERENCES group_cells(id) ON DELETE CASCADE,
      precinct_id INTEGER NOT NULL,
      PRIMARY KEY (group_id, precinct_id)
    ) WITHOUT ROWID''',
  ];

  /// Opens (creating if needed) the store at [path]. Pass
  /// [inMemoryDatabasePath] for tests.
  static Future<CustomLayerRepository> open(String path) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          for (final stmt in _schema) {
            await db.execute(stmt);
          }
        },
      ),
    );
    return CustomLayerRepository._(db);
  }

  Future<void> close() => _db.close();

  // ── Layers ──

  Future<List<CustomLayer>> loadLayers(String election, String dbName) async {
    final layerRows = await _db.query(
      'custom_layers',
      where: 'election = ? AND db_name = ?',
      whereArgs: [election, dbName],
      orderBy: 'created_at, id',
    );
    if (layerRows.isEmpty) return const [];

    final layerIds = layerRows.map((r) => r['id'] as int).toList();
    final marks = List.filled(layerIds.length, '?').join(',');
    final groupRows = await _db.query(
      'group_cells',
      where: 'layer_id IN ($marks)',
      whereArgs: layerIds,
      orderBy: 'sort_order, id',
    );
    final groupIds = groupRows.map((r) => r['id'] as int).toList();
    final precinctsByGroup = <int, Set<int>>{};
    if (groupIds.isNotEmpty) {
      final gmarks = List.filled(groupIds.length, '?').join(',');
      final rows = await _db.query(
        'group_cell_precincts',
        where: 'group_id IN ($gmarks)',
        whereArgs: groupIds,
      );
      for (final r in rows) {
        precinctsByGroup
            .putIfAbsent(r['group_id'] as int, () => {})
            .add(r['precinct_id'] as int);
      }
    }

    final groupsByLayer = <int, List<GroupCell>>{};
    for (final r in groupRows) {
      final id = r['id'] as int;
      final layerId = r['layer_id'] as int;
      groupsByLayer.putIfAbsent(layerId, () => []).add(GroupCell(
            id: id,
            layerId: layerId,
            title: r['title'] as String,
            color: Color(r['color'] as int),
            sortOrder: (r['sort_order'] as int?) ?? 0,
            precinctIds: precinctsByGroup[id] ?? <int>{},
          ));
    }

    return [
      for (final r in layerRows)
        CustomLayer(
          id: r['id'] as int,
          election: election,
          dbName: dbName,
          name: r['name'] as String,
          groups: groupsByLayer[r['id'] as int] ?? const [],
        ),
    ];
  }

  Future<int> insertLayer(
    String election,
    String dbName,
    String name, {
    required int createdAt,
  }) =>
      _db.insert('custom_layers', {
        'election': election,
        'db_name': dbName,
        'name': name,
        'created_at': createdAt,
      });

  Future<void> renameLayer(int layerId, String name) => _db.update(
        'custom_layers',
        {'name': name},
        where: 'id = ?',
        whereArgs: [layerId],
      );

  Future<void> deleteLayer(int layerId) =>
      _db.delete('custom_layers', where: 'id = ?', whereArgs: [layerId]);

  /// Drops every layer built on databases of [election]; called when that
  /// election is removed, since its precinct ids no longer mean anything.
  Future<void> deleteLayersOfElection(String election) => _db.delete(
        'custom_layers',
        where: 'election = ?',
        whereArgs: [election],
      );

  // ── Groups ──

  Future<int> insertGroup(
    int layerId,
    String title,
    Color color,
    int sortOrder,
  ) =>
      _db.insert('group_cells', {
        'layer_id': layerId,
        'title': title,
        'color': color.toARGB32(),
        'sort_order': sortOrder,
      });

  Future<void> updateGroup(int groupId, {String? title, Color? color}) {
    final values = <String, Object?>{
      if (title != null) 'title': title,
      if (color != null) 'color': color.toARGB32(),
    };
    if (values.isEmpty) return Future.value();
    return _db.update(
      'group_cells',
      values,
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  Future<void> deleteGroup(int groupId) =>
      _db.delete('group_cells', where: 'id = ?', whereArgs: [groupId]);

  // ── Membership ──

  /// Puts [precinctIds] into [groupId], taking them away from every other
  /// group of the same layer (a precinct belongs to one group at most).
  Future<void> assignPrecincts(
    int layerId,
    int groupId,
    Iterable<int> precinctIds,
  ) async {
    final ids = precinctIds.toList();
    if (ids.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final chunk in _chunks(ids, 400)) {
        final marks = List.filled(chunk.length, '?').join(',');
        batch.rawDelete(
          'DELETE FROM group_cell_precincts WHERE precinct_id IN ($marks) '
          'AND group_id IN (SELECT id FROM group_cells WHERE layer_id = ?)',
          [...chunk, layerId],
        );
        for (final p in chunk) {
          batch.insert(
            'group_cell_precincts',
            {'group_id': groupId, 'precinct_id': p},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> removePrecincts(int groupId, Iterable<int> precinctIds) async {
    final ids = precinctIds.toList();
    if (ids.isEmpty) return;
    await _db.transaction((txn) async {
      for (final chunk in _chunks(ids, 400)) {
        final marks = List.filled(chunk.length, '?').join(',');
        await txn.rawDelete(
          'DELETE FROM group_cell_precincts WHERE group_id = ? '
          'AND precinct_id IN ($marks)',
          [groupId, ...chunk],
        );
      }
    });
  }

  static Iterable<List<int>> _chunks(List<int> list, int size) sync* {
    for (var i = 0; i < list.length; i += size) {
      yield list.sublist(i, i + size > list.length ? list.length : i + size);
    }
  }
}
