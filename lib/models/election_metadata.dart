import 'package:flutter/painting.dart';

/// Candidate and party metadata for one election.
///
/// Legacy election folders (`2020-National-President`, …) carry these in the
/// elections.json manifest, copied next to the databases as `meta.json`.
/// Year folders (`2024`, …) carry them inside each state database, in the
/// `parties` / `candidates` tables, one set per contest.
class Party {
  final String id;

  /// Short code such as `DEM` / `REP`. This is the key the comparison modes
  /// join parties on across elections, since ids are minted per election —
  /// and it is what the legacy manifest used as the party's name, so both
  /// schemas meet here.
  final String name;

  /// Human-readable name (`Democrat`), when the source provides one.
  final String? fullName;
  final int colorValue;

  const Party({
    required this.id,
    required this.name,
    required this.colorValue,
    this.fullName,
  });

  Color get color => Color(colorValue);

  factory Party.fromJson(Map<String, dynamic> json) {
    return Party(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      fullName: json['full_name'] as String?,
      colorValue: (json['color'] as num?)?.toInt() ?? 0xFF9E9E9E,
    );
  }

  /// A row of the `parties` table of a year-folder state database.
  factory Party.fromDbRow(Map<String, dynamic> row) {
    return Party(
      id: row['id'].toString(),
      name: (row['code'] as String?) ?? '',
      fullName: row['name'] as String?,
      colorValue: (row['color'] as num?)?.toInt() ?? 0xFF9E9E9E,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (fullName != null) 'full_name': fullName,
        'color': colorValue,
      };
}

class Candidate {
  final String id;
  final String name;
  final String? partyId;
  final String? office;

  /// US House only: the district the candidate ran in (`3`, `At-large`).
  final String? district;

  const Candidate({
    required this.id,
    required this.name,
    this.partyId,
    this.office,
    this.district,
  });

  /// Name with the district appended for House candidates, so that lists
  /// mixing every district of a state stay readable.
  String get displayName =>
      district == null || district!.isEmpty ? name : '$name (District $district)';

  factory Candidate.fromJson(Map<String, dynamic> json) {
    return Candidate(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      partyId: json['party_id'] as String?,
      office: json['office'] as String?,
      district: json['district'] as String?,
    );
  }

  /// A row of the `candidates` table of a year-folder state database.
  factory Candidate.fromDbRow(Map<String, dynamic> row, {String? office}) {
    return Candidate(
      id: row['id'].toString(),
      name: (row['name'] as String?) ?? '',
      partyId: row['party_id'] as String?,
      office: office,
      district: row['district'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'office': office,
        'name': name,
        'party_id': partyId,
        if (district != null) 'district': district,
      };
}

/// One contest held in a state in one year: a row of the `elections` table of
/// a year-folder state database.
class ElectionContest {
  final int id;

  /// `President`, `US Senate`, `US House` or `Governor`.
  final String office;
  final String name;
  final bool special;
  final int totalVotes;

  const ElectionContest({
    required this.id,
    required this.office,
    required this.name,
    this.special = false,
    this.totalVotes = 0,
  });

  /// Short label for menus: the office, marked when it is a special election.
  String get label => special ? '$office (Special)' : office;

  /// The four offices in the order they are offered.
  static const offices = ['President', 'US Senate', 'US House', 'Governor'];

  /// Stand-in for a legacy database, which holds a single presidential contest
  /// and no `elections` table.
  static const legacyPresident = ElectionContest(
    id: 0,
    office: 'President',
    name: 'President',
  );

  factory ElectionContest.fromDbRow(Map<String, dynamic> row) {
    return ElectionContest(
      id: row['id'] as int,
      office: (row['office'] as String?) ?? '',
      name: (row['name'] as String?) ?? '',
      special: (row['special'] as int? ?? 0) != 0,
      totalVotes: (row['total_votes'] as int?) ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ElectionContest &&
          id == other.id &&
          office == other.office &&
          special == other.special;

  @override
  int get hashCode => Object.hash(id, office, special);
}
