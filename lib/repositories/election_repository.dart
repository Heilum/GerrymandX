import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ElectionRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Database get _db => _dbHelper.currentDb;

  Future<List<GeoCell>> getStates() async {
    final maps = await _db.query('states');
    return maps.map((map) => GeoCell.fromMap(map, LayerType.state)).toList();
  }

  Future<List<GeoCell>> getCounties() async {
    final maps = await _db.query('counties');
    return maps.map((map) => GeoCell.fromMap(map, LayerType.county)).toList();
  }

  Future<List<GeoCell>> getCongressionalDistricts() async {
    final maps = await _db.query('congressional_districts');
    return maps.map((map) => GeoCell.fromMap(map, LayerType.congressionalDistrict)).toList();
  }

  Future<List<GeoCell>> getPrecincts() async {
    final maps = await _db.query('precincts');
    return maps.map((map) => GeoCell.fromMap(map, LayerType.precinct)).toList();
  }

  Future<List<Candidate>> getCandidates() async {
    final maps = await _db.query('candidates');
    return maps.map((map) => Candidate.fromMap(map)).toList();
  }

  Future<List<PrecinctResult>> getPrecinctResults() async {
    final maps = await _db.query('precinct_results');
    return maps.map((map) => PrecinctResult.fromMap(map)).toList();
  }

  /// Returns {precinctId: {candidateId: votes}} for quick lookup.
  Future<Map<int, Map<int, int>>> getPrecinctVoteMap() async {
    final results = await getPrecinctResults();
    final map = <int, Map<int, int>>{};
    for (final r in results) {
      map.putIfAbsent(r.precinctId, () => {});
      map[r.precinctId]![r.candidateId] = r.votes;
    }
    return map;
  }

  /// Returns {candidateId: partyId}.
  Future<Map<int, int>> getCandidatePartyMap() async {
    final candidates = await getCandidates();
    return {for (final c in candidates) c.id: c.partyId ?? 0};
  }

  Future<void> updatePrecinctResult(int id, int votes) async {
    await _db.update(
      'precinct_results',
      {'votes': votes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
