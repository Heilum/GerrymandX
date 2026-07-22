import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class StateRegionRecord {
  final int id;
  final int stateId;
  final int regionId;
  final String regionType; // 'county' or 'congressional_district'

  StateRegionRecord({
    required this.id,
    required this.stateId,
    required this.regionId,
    required this.regionType,
  });

  factory StateRegionRecord.fromMap(Map<String, dynamic> map) {
    return StateRegionRecord(
      id: map['id'] as int,
      stateId: map['state_id'] as int,
      regionId: map['region_id'] as int,
      regionType: map['region_type'] as String,
    );
  }
}

class ElectionRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Database get _nationalDb => _dbHelper.nationalDb;

  /// Fetches all states from National.db
  Future<List<GeoCell>> getStates() async {
    final maps = await _nationalDb.query('states');
    return maps.map((map) => GeoCell.fromMap(map, LayerType.state)).toList();
  }

  /// Fetches state_regions records from National.db grouped by state_id
  Future<Map<int, List<StateRegionRecord>>> getAllStateRegions() async {
    final maps = await _nationalDb.query('state_regions');
    final result = <int, List<StateRegionRecord>>{};
    for (final map in maps) {
      final record = StateRegionRecord.fromMap(map);
      result.putIfAbsent(record.stateId, () => []).add(record);
    }
    return result;
  }

  /// Fetches counties for a state from its state DB (e.g. TX.db) using region_ids
  Future<List<GeoCell>> getCountiesForState(String dbName, List<int> regionIds) async {
    final db = await _dbHelper.getStateDb(dbName);
    final List<Map<String, dynamic>> maps;
    if (regionIds.isNotEmpty) {
      final placeholders = List.filled(regionIds.length, '?').join(',');
      maps = await db.query(
        'counties',
        where: 'id IN ($placeholders)',
        whereArgs: regionIds,
      );
    } else {
      maps = await db.query('counties');
    }
    return maps.map((map) => GeoCell.fromMap(map, LayerType.county)).toList();
  }

  /// Fetches congressional districts for a state from its state DB (e.g. TX.db) using region_ids
  Future<List<GeoCell>> getCongressionalDistrictsForState(String dbName, List<int> regionIds) async {
    final db = await _dbHelper.getStateDb(dbName);
    final List<Map<String, dynamic>> maps;
    if (regionIds.isNotEmpty) {
      final placeholders = List.filled(regionIds.length, '?').join(',');
      maps = await db.query(
        'congressional_districts',
        where: 'id IN ($placeholders)',
        whereArgs: regionIds,
      );
    } else {
      maps = await db.query('congressional_districts');
    }
    return maps.map((map) => GeoCell.fromMap(map, LayerType.congressionalDistrict)).toList();
  }

  /// Fetches all precincts from a state DB
  Future<List<GeoCell>> getPrecinctsForState(String dbName) async {
    final db = await _dbHelper.getStateDb(dbName);
    final maps = await db.query('precincts');
    return maps.map((map) => GeoCell.fromMap(map, LayerType.precinct)).toList();
  }

  /// Fetches candidates from National.db
  Future<List<Candidate>> getCandidates() async {
    try {
      final db = _dbHelper.nationalDb;
      final maps = await db.query('candidates');
      return maps.map((map) => Candidate.fromMap(map)).toList();
    } catch (e) {
      return [];
    }
  }

  /// Returns {candidateId: partyId} from National.db.
  Future<Map<int, int>> getCandidatePartyMap() async {
    final candidates = await getCandidates();
    return {for (final c in candidates) c.id: c.partyId ?? 0};
  }

  /// Fetches candidates from a state DB (or National.db fallback)
  Future<List<Candidate>> getCandidatesForState(String dbName) async {
    try {
      final db = await _dbHelper.getStateDb(dbName);
      final maps = await db.query('candidates');
      if (maps.isNotEmpty) {
        return maps.map((map) => Candidate.fromMap(map)).toList();
      }
    } catch (_) {}
    return getCandidates();
  }

  /// Fetches precinct results from a state DB
  Future<List<PrecinctResult>> getPrecinctResultsForState(String dbName) async {
    final db = await _dbHelper.getStateDb(dbName);
    final maps = await db.query('precinct_results');
    return maps.map((map) => PrecinctResult.fromMap(map)).toList();
  }

  /// Returns {precinctId: {candidateId: votes}} for quick lookup.
  Future<Map<int, Map<int, int>>> getPrecinctVoteMapForState(String dbName) async {
    final results = await getPrecinctResultsForState(dbName);
    final map = <int, Map<int, int>>{};
    for (final r in results) {
      map.putIfAbsent(r.precinctId, () => {});
      map[r.precinctId]![r.candidateId] = r.votes;
    }
    return map;
  }

  /// Returns {candidateId: partyId}.
  Future<Map<int, int>> getCandidatePartyMapForState(String dbName) async {
    final candidates = await getCandidatesForState(dbName);
    return {for (final c in candidates) c.id: c.partyId ?? 0};
  }

  /// Returns {countyId: [precinctId, ...]}.
  Future<Map<int, List<int>>> getCountyPrecinctMapForState(String dbName) async {
    final db = await _dbHelper.getStateDb(dbName);
    final rows = await db.query('county_precincts');
    final map = <int, List<int>>{};
    for (final row in rows) {
      final countyId = row['county_id'] as int;
      final precinctId = row['precinct_id'] as int;
      map.putIfAbsent(countyId, () => []).add(precinctId);
    }
    return map;
  }

  /// Returns {congressionalDistrictId: [precinctId, ...]}.
  Future<Map<int, List<int>>> getCdPrecinctMapForState(String dbName) async {
    final db = await _dbHelper.getStateDb(dbName);
    final rows = await db.query('congressional_district_precincts');
    final map = <int, List<int>>{};
    for (final row in rows) {
      final cdId = row['congressional_district_id'] as int;
      final precinctId = row['precinct_id'] as int;
      map.putIfAbsent(cdId, () => []).add(precinctId);
    }
    return map;
  }

  Future<void> updatePrecinctResultForState(String dbName, int id, int votes) async {
    final db = await _dbHelper.getStateDb(dbName);
    await db.update(
      'precinct_results',
      {'votes': votes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
