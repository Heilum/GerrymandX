import 'package:gerrymanderx/models/election_metadata.dart';

class RemoteDbItem {
  final String name;
  final String url;

  /// Byte size and SHA-256 of the file on the CDN, from a versioned manifest.
  /// A downloaded copy whose hash differs is out of date.
  final int? size;
  final String? sha256;

  RemoteDbItem({
    required this.name,
    required this.url,
    this.size,
    this.sha256,
  });

  static const String _cdnBase = 'https://files.xp-oncology.cn/gerrymander/';

  static String _ensureCdnUrl(String rawUrl) {
    return rawUrl
        .replaceAll('https://xp-oncology.cn/gerrymander/', _cdnBase)
        .replaceAll(
          'https://public-assets.peipeixiong.cn/public/jagie/gerrymander/',
          _cdnBase,
        );
  }

  factory RemoteDbItem.fromJson(dynamic json) {
    if (json is String) {
      final fixedUrl = _ensureCdnUrl(json);
      final filename = Uri.parse(fixedUrl).pathSegments.last;
      return RemoteDbItem(name: filename, url: fixedUrl);
    } else if (json is Map<String, dynamic>) {
      // Legacy manifest: {name, url}. Year manifest: {stateName, db}.
      final rawUrl = (json['url'] ?? json['db']) as String;
      final name = (json['name'] ?? json['stateName']) as String? ??
          Uri.parse(rawUrl).pathSegments.last;
      return RemoteDbItem(
        name: name,
        url: _ensureCdnUrl(rawUrl),
        size: (json['size'] as num?)?.toInt(),
        sha256: json['sha256'] as String?,
      );
    }
    throw FormatException('Invalid db item format: $json');
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        if (size != null) 'size': size,
        if (sha256 != null) 'sha256': sha256,
      };
}

/// One downloadable election folder: a legacy election such as
/// `2024-National-President`, or a year such as `2024` whose databases each
/// hold every contest of one state.
class RemoteElectionItem {
  final String name;
  final String description;
  final List<Candidate> candidates;
  final List<Party> parties;
  final List<RemoteDbItem> dbs;

  RemoteElectionItem({
    required this.name,
    required this.description,
    this.candidates = const [],
    this.parties = const [],
    required this.dbs,
  });

  factory RemoteElectionItem.fromJson(Map<String, dynamic> json) {
    return RemoteElectionItem(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      candidates: (json['candidates'] as List<dynamic>? ?? [])
          .map((e) => Candidate.fromJson(e as Map<String, dynamic>))
          .toList(),
      parties: (json['parties'] as List<dynamic>? ?? [])
          .map((e) => Party.fromJson(e as Map<String, dynamic>))
          .toList(),
      dbs: (json['dbs'] as List<dynamic>).map((e) => RemoteDbItem.fromJson(e)).toList(),
    );
  }

  /// Parses either manifest shape.
  ///
  /// The legacy `elections.json` is a list of elections with their candidates
  /// and parties. `new_elections.json` is keyed by year —
  /// `{"2024": [{"stateName": "Texas", "db": "…/TX-2024.db"}, …]}` — and each
  /// year becomes one item whose folder name is the year; candidates and
  /// parties live in the databases themselves.
  ///
  /// A versioned `new_elections.json` also carries a top-level `version`,
  /// which is skipped here (see [manifestVersionOf]).
  static List<RemoteElectionItem> listFromManifest(dynamic decoded) {
    if (decoded is List) {
      return decoded
          .map((e) => RemoteElectionItem.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (decoded is Map<String, dynamic>) {
      final years = decoded.keys.toList()..sort((a, b) => b.compareTo(a));
      return [
        for (final year in years)
          if (decoded[year] is List)
            RemoteElectionItem(
              name: year,
              description: '$year elections',
              dbs: (decoded[year] as List<dynamic>)
                  .map((e) => RemoteDbItem.fromJson(e))
                  .toList(),
            ),
      ];
    }
    throw FormatException('Unrecognised elections manifest: ${decoded.runtimeType}');
  }

  /// The `version` of a `new_elections.json`; null for a manifest without one.
  static int? manifestVersionOf(dynamic decoded) =>
      decoded is Map<String, dynamic> ? (decoded['version'] as num?)?.toInt() : null;

  /// Written to `meta.json` inside the downloaded election folder so that
  /// candidates and parties are available without the remote manifest.
  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'candidates': candidates.map((c) => c.toJson()).toList(),
        'parties': parties.map((p) => p.toJson()).toList(),
        'dbs': dbs.map((d) => d.toJson()).toList(),
      };
}
