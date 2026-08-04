import 'package:flutter/painting.dart';

/// Candidate and party metadata for one election.
///
/// These used to live in the `candidates` / `parties` tables of National.db.
/// They now come from the elections.json manifest, and a copy is written next to the
/// downloaded databases as `election.json` so the app still works offline.
class Party {
  final String id;
  final String name;
  final int colorValue;

  const Party({required this.id, required this.name, required this.colorValue});

  Color get color => Color(colorValue);

  factory Party.fromJson(Map<String, dynamic> json) {
    return Party(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      colorValue: (json['color'] as num?)?.toInt() ?? 0xFF9E9E9E,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': colorValue};
}

class Candidate {
  final String id;
  final String name;
  final String? partyId;
  final String? office;

  const Candidate({
    required this.id,
    required this.name,
    this.partyId,
    this.office,
  });

  factory Candidate.fromJson(Map<String, dynamic> json) {
    return Candidate(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      partyId: json['party_id'] as String?,
      office: json['office'] as String?,
    );
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'office': office, 'name': name, 'party_id': partyId};
}
