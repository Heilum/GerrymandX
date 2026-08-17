

import 'dart:typed_data';

enum LayerType {
  state,
  county,
  congressionalDistrict,
  precinct,

  /// A user-defined layer: its cells are group cells (sets of precincts) from
  /// the currently active [CustomLayer]. Toggled through the custom-layer
  /// picker rather than the layer chips.
  custom,
}

extension LayerTypeInfo on LayerType {
  /// The layers every state database carries, i.e. everything a user can pick
  /// cells from when building a custom layer.
  bool get isBuiltInStateLayer =>
      this == LayerType.county ||
      this == LayerType.congressionalDistrict ||
      this == LayerType.precinct;
}

class GeoCell {
  final int id;
  final String name;
  final Uint8List? boundaryWkb;
  final LayerType layerType;
  final int population; // For precinct, directly from DB. For others, aggregated.
  final double? centerLat;
  final double? centerLon;
  final String? dbName;
  final String? voteSummaryJson;

  GeoCell({
    required this.id,
    required this.name,
    this.boundaryWkb,
    required this.layerType,
    this.population = 0,
    this.centerLat,
    this.centerLon,
    this.dbName,
    this.voteSummaryJson,
  });

  factory GeoCell.fromMap(Map<String, dynamic> map, LayerType type) {
    return GeoCell(
      id: map['id'] as int,
      name: map['name'] as String,
      boundaryWkb: map['boundary'] as Uint8List?,
      layerType: type,
      population: map['population'] ?? 0,
      centerLat: map['center_lat'] as double?,
      centerLon: map['center_lon'] as double?,
      dbName: map['db_name'] as String?,
      voteSummaryJson: map['vote_summary'] as String?,
    );
  }
}

class PrecinctResult {
  final int id;
  final int precinctId;

  /// Candidate UUID. Candidates live in the election manifest, not in the DB.
  final String candidateId;
  final int votes;

  PrecinctResult({
    required this.id,
    required this.precinctId,
    required this.candidateId,
    required this.votes,
  });

  factory PrecinctResult.fromMap(Map<String, dynamic> map) {
    return PrecinctResult(
      id: map['id'] as int,
      precinctId: map['precinct_id'] as int,
      candidateId: map['candidate_id'].toString(),
      votes: map['votes'] as int,
    );
  }
}
