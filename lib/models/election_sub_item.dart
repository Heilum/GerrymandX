class ElectionSubItem {
  final String name; // 'National' or 'Texas'
  final bool isNational; // true for National, false for state
  final String? dbName; // null for National, 'TX.db' for state
  final int? stateId;

  const ElectionSubItem({
    required this.name,
    required this.isNational,
    this.dbName,
    this.stateId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ElectionSubItem &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          isNational == other.isNational &&
          dbName == other.dbName;

  @override
  int get hashCode => name.hashCode ^ isNational.hashCode ^ (dbName?.hashCode ?? 0);
}
