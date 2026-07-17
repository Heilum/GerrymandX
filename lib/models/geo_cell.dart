

enum LayerType { state, county, congressionalDistrict, precinct }

class GeoCell {
  final int id;
  final String name;
  final String? boundaryJson;
  final LayerType layerType;
  final int population; // For precinct, directly from DB. For others, aggregated.

  GeoCell({
    required this.id,
    required this.name,
    this.boundaryJson,
    required this.layerType,
    this.population = 0,
  });

  factory GeoCell.fromMap(Map<String, dynamic> map, LayerType type) {
    return GeoCell(
      id: map['id'] as int,
      name: map['name'] as String,
      boundaryJson: map['boundary'] as String?,
      layerType: type,
      population: map['population'] ?? 0,
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
