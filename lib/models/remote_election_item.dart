import 'package:gerrymanderx/models/election_metadata.dart';

class RemoteDbItem {
  final String name;
  final String url;

  RemoteDbItem({
    required this.name,
    required this.url,
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
      final rawUrl = json['url'] as String;
      return RemoteDbItem(
        name: json['name'] as String,
        url: _ensureCdnUrl(rawUrl),
      );
    }
    throw FormatException('Invalid db item format: $json');
  }

  Map<String, dynamic> toJson() => {'name': name, 'url': url};
}

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

  /// Written to `election.json` inside the downloaded election folder so that
  /// candidates and parties are available without the remote manifest.
  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'candidates': candidates.map((c) => c.toJson()).toList(),
        'parties': parties.map((p) => p.toJson()).toList(),
        'dbs': dbs.map((d) => d.toJson()).toList(),
      };
}
