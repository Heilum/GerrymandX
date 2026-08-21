import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/repositories/election_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The comparison modes read a state database belonging to another election,
/// so these queries name their tables with nothing else to catch a typo. They
/// run here against the real schema (python-scripts/schema.sql) built in
/// memory.
void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    for (final statement in [
      'CREATE TABLE precincts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL, population INTEGER NOT NULL DEFAULT 0)',
      'CREATE TABLE precinct_results (id INTEGER PRIMARY KEY AUTOINCREMENT, precinct_id INTEGER, candidate_id TEXT, votes INTEGER NOT NULL DEFAULT 0, UNIQUE(precinct_id, candidate_id))',
    ]) {
      await db.execute(statement);
    }

    await db.insert('precincts',
        {'id': 10, 'name': 'P-10', 'center_lat': 31.5, 'center_lon': -97.25});
    await db.insert('precincts', {'id': 11, 'name': 'P-11'});
    await db.insert('precinct_results',
        {'precinct_id': 10, 'candidate_id': 'cand-a', 'votes': 30});
    await db.insert('precinct_results',
        {'precinct_id': 10, 'candidate_id': 'cand-b', 'votes': 20});
    await db.insert('precinct_results',
        {'precinct_id': 11, 'candidate_id': 'cand-a', 'votes': 5});
  });

  tearDown(() => db.close());

  test('reads precinct results keyed by precinct and candidate', () async {
    final votes = await ElectionRepository().loadPrecinctVoteMap(db);

    expect(votes, {
      10: {'cand-a': 30, 'cand-b': 20},
      11: {'cand-a': 5},
    });
  });

  test('reads candidate ids stored as integers by older builds', () async {
    await db.delete('precinct_results');
    await db.insert('precinct_results',
        {'precinct_id': 10, 'candidate_id': 1, 'votes': 7});

    final votes = await ElectionRepository().loadPrecinctVoteMap(db);

    expect(votes, {
      10: {'1': 7},
    });
  });

  test('reads precinct geometry with its stored centre', () async {
    final cells = await ElectionRepository().loadPrecinctGeometry(db);

    expect(cells.map((c) => c.id), [10, 11]);
    expect(cells.first.layerType, LayerType.precinct);
    expect(cells.first.centerLat, 31.5);
    expect(cells.first.centerLon, -97.25);
    expect(cells.last.centerLat, isNull);
  });

  test('treats a missing table as no data', () async {
    await db.execute('DROP TABLE precinct_results');
    await db.execute('DROP TABLE precincts');
    final repo = ElectionRepository();

    expect(await repo.loadPrecinctVoteMap(db), isEmpty);
    expect(await repo.loadPrecinctGeometry(db), isEmpty);
  });
}
