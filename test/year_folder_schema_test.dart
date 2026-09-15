import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/models/remote_election_item.dart';
import 'package:gerrymanderx/repositories/election_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Year folders (`2024/TX-2024.db`) keep every contest of a state in one
/// database, with parties and candidates per contest. These tests pin the
/// reads against the schema python-scripts/build_2024_state_dbs.py writes, and
/// the manifest shape new_elections.json uses.
void main() {
  sqfliteFfiInit();

  group('new_elections.json', () {
    test('maps each year to one folder whose databases are the states', () {
      final items = RemoteElectionItem.listFromManifest({
        '2024': [
          {'stateName': 'Texas', 'db': 'https://files.xp-oncology.cn/gerrymander/2024/TX-2024.db'},
          {'stateName': 'Kansas', 'db': 'https://files.xp-oncology.cn/gerrymander/2024/KS-2024.db'},
        ],
        '2020': [
          {'stateName': 'Texas', 'db': 'https://files.xp-oncology.cn/gerrymander/2020/TX-2020.db'},
        ],
      });

      expect(items.map((i) => i.name), ['2024', '2020'], reason: 'newest first');
      expect(items.first.dbs.map((d) => d.name), ['Texas', 'Kansas']);
      expect(items.first.dbs.first.url, endsWith('/2024/TX-2024.db'));
      expect(items.first.candidates, isEmpty,
          reason: 'candidates live in the databases, not the manifest');
    });

    test('still reads the legacy list manifest', () {
      final items = RemoteElectionItem.listFromManifest([
        {
          'name': '2024-National-President',
          'description': 'x',
          'dbs': [
            {'name': 'Texas', 'url': 'https://files.xp-oncology.cn/gerrymander/2024-National-President/TX.db'},
          ],
        },
      ]);
      expect(items.single.name, '2024-National-President');
      expect(items.single.dbs.single.name, 'Texas');
    });
  });

  test('the same state is recognised across folder naming schemes', () {
    expect(ElectionSubItem.stateCodeOf('TX.db'), 'TX');
    expect(ElectionSubItem.stateCodeOf('TX-2024.db'), 'TX');
    expect(ElectionSubItem.stateCodeOf('National.db'), isNull);
    expect(ElectionSubItem.stateCodeOf(null), isNull);
  });

  group('year-folder database', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      for (final statement in [
        'CREATE TABLE precincts (id INTEGER PRIMARY KEY, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL)',
        "CREATE TABLE elections (id INTEGER PRIMARY KEY, office TEXT NOT NULL, name TEXT NOT NULL, year INTEGER NOT NULL, special INTEGER NOT NULL DEFAULT 0, source TEXT, total_votes INTEGER NOT NULL DEFAULT 0)",
        'CREATE TABLE parties (id TEXT PRIMARY KEY, election_id INTEGER NOT NULL, code TEXT NOT NULL, name TEXT NOT NULL, color INTEGER NOT NULL)',
        'CREATE TABLE candidates (id TEXT PRIMARY KEY, election_id INTEGER NOT NULL, party_id TEXT, code TEXT NOT NULL, name TEXT NOT NULL, district TEXT, congressional_district_id INTEGER, votes INTEGER NOT NULL DEFAULT 0)',
        'CREATE TABLE precinct_results (id INTEGER PRIMARY KEY AUTOINCREMENT, precinct_id INTEGER NOT NULL, election_id INTEGER NOT NULL, candidate_id TEXT NOT NULL, votes INTEGER NOT NULL DEFAULT 0, UNIQUE(precinct_id, candidate_id))',
        'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)',
      ]) {
        await db.execute(statement);
      }
      await db.insert('meta', {'key': 'state_code', 'value': 'KS'});
      await db.insert('meta', {'key': 'state_name', 'value': 'Kansas'});
      await db.insert('precincts', {'id': 1, 'name': 'P1'});
      await db.insert('elections', {'id': 1, 'office': 'President', 'name': '2024 Kansas President', 'year': 2024, 'total_votes': 130});
      await db.insert('elections', {'id': 2, 'office': 'US House', 'name': '2024 Kansas US House', 'year': 2024, 'total_votes': 120});
      await db.insert('parties', {'id': 'p-dem-1', 'election_id': 1, 'code': 'DEM', 'name': 'Democrat', 'color': 0xFF2166AC});
      await db.insert('parties', {'id': 'p-rep-1', 'election_id': 1, 'code': 'REP', 'name': 'Republican', 'color': 0xFFB2182B});
      await db.insert('parties', {'id': 'p-dem-2', 'election_id': 2, 'code': 'DEM', 'name': 'Democrat', 'color': 0xFF2166AC});
      await db.insert('candidates', {'id': 'c-har', 'election_id': 1, 'party_id': 'p-dem-1', 'code': 'HAR', 'name': 'Harris', 'votes': 50});
      await db.insert('candidates', {'id': 'c-tru', 'election_id': 1, 'party_id': 'p-rep-1', 'code': 'TRU', 'name': 'Trump', 'votes': 80});
      await db.insert('candidates', {'id': 'c-dav', 'election_id': 2, 'party_id': 'p-dem-2', 'code': '3-DDAV', 'name': 'Sharice Davids', 'district': '3', 'votes': 120});
      await db.insert('precinct_results', {'precinct_id': 1, 'election_id': 1, 'candidate_id': 'c-har', 'votes': 50});
      await db.insert('precinct_results', {'precinct_id': 1, 'election_id': 1, 'candidate_id': 'c-tru', 'votes': 80});
      await db.insert('precinct_results', {'precinct_id': 1, 'election_id': 2, 'candidate_id': 'c-dav', 'votes': 120});
    });

    tearDown(() => db.close());

    test('is told apart from a legacy database by its elections table', () async {
      final repo = ElectionRepository();
      expect(await repo.hasElectionsTable(db), isTrue);
      await db.execute('DROP TABLE elections');
      expect(await repo.hasElectionsTable(db), isFalse);
    });

    test('lists its contests in build order with their labels', () async {
      final contests = await ElectionRepository().loadElections(db);
      expect(contests.map((c) => c.office), ['President', 'US House']);
      expect(contests.first.label, 'President');
      expect(contests.first.special, isFalse);
    });

    test('scopes parties, candidates and votes to one contest', () async {
      final repo = ElectionRepository();

      final parties = await repo.loadParties(db, 1);
      expect(parties.map((p) => p.name), ['DEM', 'REP'],
          reason: 'the code is the party name: it is the cross-election join key');
      expect(parties.first.fullName, 'Democrat');

      final house = await repo.loadCandidates(db, 2, office: 'US House');
      expect(house.single.displayName, 'Sharice Davids (District 3)');
      expect(house.single.office, 'US House');

      expect(await repo.loadPrecinctVoteMap(db, electionId: 1), {
        1: {'c-har': 50, 'c-tru': 80},
      });
      expect(await repo.loadPrecinctVoteMap(db, electionId: 2), {
        1: {'c-dav': 120},
      });
      expect(await repo.loadPrecinctVoteMap(db), {
        1: {'c-har': 50, 'c-tru': 80, 'c-dav': 120},
      }, reason: 'no contest given reads everything, as for a legacy database');
    });

    test('names itself through the meta table', () async {
      final meta = await ElectionRepository().loadDbMeta(db);
      expect(meta['state_name'], 'Kansas');
      expect(meta['state_code'], 'KS');
    });
  });
}
