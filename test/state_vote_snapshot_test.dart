import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/repositories/election_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// [ElectionRepository.loadStateVoteSnapshot] reads a state database belonging
/// to another election, so it queries tables by name with nothing else to
/// catch a typo. These tests run it against the real schema
/// (python-scripts/schema.sql) built in memory.
void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    for (final statement in [
      'CREATE TABLE counties (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL)',
      'CREATE TABLE congressional_districts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL)',
      'CREATE TABLE precincts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL, population INTEGER NOT NULL DEFAULT 0)',
      'CREATE TABLE county_precincts (precinct_id INTEGER, county_id INTEGER, PRIMARY KEY(precinct_id, county_id))',
      'CREATE TABLE congressional_district_precincts (precinct_id INTEGER, congressional_district_id INTEGER, PRIMARY KEY(precinct_id, congressional_district_id))',
      'CREATE TABLE precinct_results (id INTEGER PRIMARY KEY AUTOINCREMENT, precinct_id INTEGER, candidate_id TEXT, votes INTEGER NOT NULL DEFAULT 0, UNIQUE(precinct_id, candidate_id))',
    ]) {
      await db.execute(statement);
    }

    await db.insert('counties', {'id': 1, 'name': 'Anderson'});
    await db.insert('congressional_districts', {'id': 7, 'name': 'District 1'});
    await db.insert('precincts', {'id': 10, 'name': 'P-10'});
    await db.insert('precincts', {'id': 11, 'name': 'P-11'});
    await db.insert('county_precincts', {'county_id': 1, 'precinct_id': 10});
    await db.insert('county_precincts', {'county_id': 1, 'precinct_id': 11});
    await db.insert('congressional_district_precincts',
        {'congressional_district_id': 7, 'precinct_id': 10});
    await db.insert('precinct_results',
        {'precinct_id': 10, 'candidate_id': 'cand-a', 'votes': 30});
    await db.insert('precinct_results',
        {'precinct_id': 10, 'candidate_id': 'cand-b', 'votes': 20});
    await db.insert('precinct_results',
        {'precinct_id': 11, 'candidate_id': 'cand-a', 'votes': 5});
  });

  tearDown(() => db.close());

  test('reads names, memberships and votes from the real schema', () async {
    final snapshot = await ElectionRepository().loadStateVoteSnapshot(db);

    expect(snapshot.countyNames, {1: 'Anderson'});
    expect(snapshot.cdNames, {7: 'District 1'});
    expect(snapshot.precinctNames, {10: 'P-10', 11: 'P-11'});
    expect(snapshot.countyPrecincts, {
      1: [10, 11],
    });
    expect(snapshot.cdPrecincts, {
      7: [10],
    });
    expect(snapshot.precinctVotes, {
      10: {'cand-a': 30, 'cand-b': 20},
      11: {'cand-a': 5},
    });
  });

  test('treats a missing table as no data for that layer', () async {
    await db.execute('DROP TABLE congressional_district_precincts');
    await db.execute('DROP TABLE congressional_districts');

    final snapshot = await ElectionRepository().loadStateVoteSnapshot(db);

    expect(snapshot.cdNames, isEmpty);
    expect(snapshot.cdPrecincts, isEmpty);
    expect(snapshot.countyPrecincts, isNotEmpty);
  });
}
