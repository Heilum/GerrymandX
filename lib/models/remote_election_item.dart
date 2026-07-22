class RemoteElectionItem {
  final String name;
  final String description;
  final List<String> dbs;

  RemoteElectionItem({
    required this.name,
    required this.description,
    required this.dbs,
  });

  factory RemoteElectionItem.fromJson(Map<String, dynamic> json) {
    return RemoteElectionItem(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      dbs: (json['dbs'] as List<dynamic>).map((e) => e as String).toList(),
    );
  }
}
