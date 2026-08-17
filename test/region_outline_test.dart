import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/core/utils/region_outline.dart';

/// The custom-layer outline is the set of precinct edges that no neighbour in
/// the set shares. These tests build tiny tessellations by hand.
void main() {
  List<List<double>> square(double x, double y, [double s = 1]) => [
        [x, y],
        [x + s, y],
        [x + s, y + s],
        [x, y + s],
        [x, y],
      ];

  /// Total length of every segment in [path]: an outline of a 2×1 rectangle
  /// has perimeter 6 whichever way its vertices are chained.
  double perimeter(Path path) {
    var total = 0.0;
    for (final m in path.computeMetrics()) {
      total += m.length;
    }
    return total;
  }

  test('two adjacent squares outline as one rectangle', () {
    final path = RegionOutline.outline([square(0, 0), square(1, 0)]);
    expect(perimeter(path), closeTo(6.0, 1e-9));
    expect(path.getBounds(), const Rect.fromLTRB(0, 0, 2, 1));
  });

  test('a lone square keeps its whole boundary', () {
    expect(perimeter(RegionOutline.outline([square(0, 0)])), closeTo(4, 1e-9));
  });

  test('a ring of squares around a hole keeps the inner boundary', () {
    // 3×3 block minus the centre: outer perimeter 12, hole perimeter 4.
    final rings = [
      for (var x = 0; x < 3; x++)
        for (var y = 0; y < 3; y++)
          if (!(x == 1 && y == 1)) square(x.toDouble(), y.toDouble()),
    ];
    expect(perimeter(RegionOutline.outline(rings)), closeTo(16, 1e-9));
  });

  test('a filled hole cancels the interior ring', () {
    // Outer square with a hole, plus the square that fills the hole.
    final outerWithHole = [square(0, 0, 3), square(1, 1)];
    final rings = [...outerWithHole, square(1, 1)];
    expect(perimeter(RegionOutline.outline(rings)), closeTo(12, 1e-9));
  });

  test('two separate pieces each keep their outline', () {
    final path = RegionOutline.outline([square(0, 0), square(5, 5)]);
    expect(perimeter(path), closeTo(8, 1e-9));
  });

  test('opposite winding directions still cancel', () {
    final reversed = square(1, 0).reversed.toList();
    expect(
      perimeter(RegionOutline.outline([square(0, 0), reversed])),
      closeTo(6, 1e-9),
    );
  });
}
