

import 'dart:typed_data';

enum LayerType { state, county, congressionalDistrict, precinct }

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

class Candidate {
  final int id;
  final String name;
  final int? partyId;
  final String? office;

  Candidate({
    required this.id,
    required this.name,
    this.partyId,
    this.office,
  });

  factory Candidate.fromMap(Map<String, dynamic> map) {
    return Candidate(
      id: map['id'] as int,
      name: map['name'] as String,
      partyId: map['party_id'] as int?,
      office: map['office'] as String?,
    );
  }
}

class PrecinctResult {
  final int id;
  final int precinctId;
  final int candidateId;
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
      candidateId: map['candidate_id'] as int,
      votes: map['votes'] as int,
    );
  }
}
