import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// One cell of a [CustomLayer]: a named, coloured set of precincts. Stands
/// where a county or congressional district stands in the built-in layers.
class GroupCell {
  final int id;
  final int layerId;
  final String title;
  final Color color;
  final int sortOrder;

  /// Precinct ids of the state database the owning layer belongs to.
  final Set<int> precinctIds;

  const GroupCell({
    required this.id,
    required this.layerId,
    required this.title,
    required this.color,
    required this.sortOrder,
    required this.precinctIds,
  });

  GroupCell copyWith({
    String? title,
    Color? color,
    int? sortOrder,
    Set<int>? precinctIds,
  }) =>
      GroupCell(
        id: id,
        layerId: layerId,
        title: title ?? this.title,
        color: color ?? this.color,
        sortOrder: sortOrder ?? this.sortOrder,
        precinctIds: precinctIds ?? this.precinctIds,
      );

  /// Palette group colours are picked from: distinct hues at two lightnesses.
  /// New groups take the next unused entry, so a fresh layer's groups are
  /// told apart at a glance; the picker offers the same set plus "random".
  static const palette = <Color>[
    Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF43A047), Color(0xFFFB8C00),
    Color(0xFF8E24AA), Color(0xFF00ACC1), Color(0xFFFDD835), Color(0xFFD81B60),
    Color(0xFF5E35B1), Color(0xFF7CB342), Color(0xFFF4511E), Color(0xFF3949AB),
    Color(0xFF00897B), Color(0xFFC0CA33), Color(0xFFFFB300), Color(0xFF039BE5),
    Color(0xFFEF9A9A), Color(0xFF90CAF9), Color(0xFFA5D6A7), Color(0xFFFFCC80),
    Color(0xFFCE93D8), Color(0xFF80DEEA), Color(0xFFFFF59D), Color(0xFFBCAAA4),
  ];

  /// First palette colour not used by [taken], or a random one once the
  /// palette is exhausted.
  static Color nextColor(Iterable<Color> taken) {
    final used = taken.map((c) => c.toARGB32()).toSet();
    for (final c in palette) {
      if (!used.contains(c.toARGB32())) return c;
    }
    return randomColor();
  }

  /// A distinguishable, reasonably saturated colour for a new group.
  static Color randomColor([math.Random? random]) {
    final r = random ?? math.Random();
    return HSLColor.fromAHSL(1.0, r.nextDouble() * 360, 0.65, 0.55).toColor();
  }
}

/// A user-defined map layer over one state of one election.
///
/// Scoped to `<election>/<dbName>` and not just to the state: precinct ids are
/// minted per election database (2020 and 2024 number the same state's
/// precincts differently), so a precinct set only means something for the
/// database it was built on.
class CustomLayer {
  final int id;
  final String election;
  final String dbName;
  final String name;
  final List<GroupCell> groups;

  const CustomLayer({
    required this.id,
    required this.election,
    required this.dbName,
    required this.name,
    required this.groups,
  });

  CustomLayer copyWith({String? name, List<GroupCell>? groups}) => CustomLayer(
        id: id,
        election: election,
        dbName: dbName,
        name: name ?? this.name,
        groups: groups ?? this.groups,
      );

  GroupCell? groupById(int id) =>
      groups.where((g) => g.id == id).firstOrNull;

  /// {precinctId: groupId} — a precinct belongs to at most one group.
  Map<int, int> get groupOfPrecinct => {
        for (final g in groups)
          for (final p in g.precinctIds) p: g.id,
      };
}
