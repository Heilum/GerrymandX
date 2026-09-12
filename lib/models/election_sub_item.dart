class ElectionSubItem {
  final String name; // 'National' or 'Texas'
  final bool isNational; // true for National, false for state
  final String? dbName; // null for National, 'TX.db' or 'TX-2024.db' for state
  final int? stateId;

  const ElectionSubItem({
    required this.name,
    required this.isNational,
    this.dbName,
    this.stateId,
  });

  /// Two-letter state code taken from the database file name, which is how
  /// the same state is recognised across election folders that name their
  /// files differently (`TX.db` in the legacy folders, `TX-2024.db` in the
  /// year folders).
  String? get stateCode => stateCodeOf(dbName);

  static String? stateCodeOf(String? dbName) {
    if (dbName == null || dbName.isEmpty) return null;
    final stem = dbName.endsWith('.db')
        ? dbName.substring(0, dbName.length - 3)
        : dbName;
    final code = stem.split('-').first;
    if (code.isEmpty || code == 'National') return null;
    return code.toUpperCase();
  }

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
