import 'dart:collection';
import 'dart:ui';

import 'package:gerrymanderx/core/utils/geojson_parser.dart';

/// Builds the outline of a set of precincts without any polygon boolean ops.
///
/// Precinct polygons tessellate the state and, in our databases, share their
/// borders vertex for vertex (the importer snaps every vertex to one grid). So
/// an edge that occurs in exactly one precinct ring of the set lies on the
/// set's boundary, and an edge that occurs twice is interior and cancels out.
/// That makes the outline an O(V) counting pass, robust to arbitrary shapes
/// (holes, several pieces, enclaves) — verified against a real county: the
/// surviving edges reproduce the stored county ring exactly.
class RegionOutline {
  RegionOutline._();

  /// Grid the vertices are keyed on. Finer than the importer's 1e-5° snap so
  /// it never merges distinct vertices, coarse enough to absorb float noise.
  ///
  /// Longitudes reach ±180° → ±1.8e8 quanta; with the offset that is < 2^29,
  /// so two coordinates pack into one 58-bit key without collisions.
  static const _quantum = 1e-6;
  static const _offset = 1 << 28; // keeps quantised coordinates positive
  static const _shift = 29;

  static int _pointKey(double x, double y) {
    final ix = (x / _quantum).round() + _offset;
    final iy = (y / _quantum).round() + _offset;
    return (ix << _shift) | iy;
  }

  /// Segments of [rings] that appear exactly once, as a stroke-only [Path].
  ///
  /// [rings] are polylines (closed or not) in map coordinates — pass every
  /// exterior *and* interior ring of every member polygon, since a hole
  /// filled by another member has to cancel too.
  static Path outline(Iterable<List<List<double>>> rings) {
    // edge key → (count, ax, ay, bx, by). Edges are keyed with endpoints in a
    // canonical order so the two directions of a shared border coincide.
    final counts = HashMap<int, HashMap<int, int>>();
    final points = HashMap<int, Offset>();

    for (final ring in rings) {
      if (ring.length < 2) continue;
      var prevKey = _pointKey(ring[0][0], ring[0][1]);
      points[prevKey] = Offset(ring[0][0], ring[0][1]);
      for (var i = 1; i < ring.length; i++) {
        final key = _pointKey(ring[i][0], ring[i][1]);
        if (key == prevKey) continue;
        points.putIfAbsent(key, () => Offset(ring[i][0], ring[i][1]));
        final a = key < prevKey ? key : prevKey;
        final b = key < prevKey ? prevKey : key;
        final row = counts.putIfAbsent(a, () => HashMap<int, int>());
        row[b] = (row[b] ?? 0) + 1;
        prevKey = key;
      }
    }

    // Boundary edges, as adjacency so they can be chained into polylines
    // (fewer subpaths, clean joins).
    final adjacency = HashMap<int, List<int>>();
    counts.forEach((a, row) {
      row.forEach((b, n) {
        if (n != 1) return;
        adjacency.putIfAbsent(a, () => []).add(b);
        adjacency.putIfAbsent(b, () => []).add(a);
      });
    });

    final path = Path();
    while (adjacency.isNotEmpty) {
      final start = adjacency.keys.first;
      var current = start;
      final first = points[start]!;
      path.moveTo(first.dx, first.dy);
      while (true) {
        final next = _popNeighbour(adjacency, current);
        if (next == null) break;
        final p = points[next]!;
        path.lineTo(p.dx, p.dy);
        current = next;
        if (current == start) {
          path.close();
          break;
        }
      }
    }
    return path;
  }

  /// Removes and returns one edge out of [node], or null when it has none
  /// left (dropping the node so the outer loop terminates).
  static int? _popNeighbour(HashMap<int, List<int>> adjacency, int node) {
    final list = adjacency[node];
    if (list == null || list.isEmpty) {
      adjacency.remove(node);
      return null;
    }
    final next = list.removeLast();
    if (list.isEmpty) adjacency.remove(node);
    final back = adjacency[next];
    if (back != null) {
      back.remove(node);
      if (back.isEmpty) adjacency.remove(next);
    }
    return next;
  }

  /// Convenience: outline of the polygons parsed from [coords].
  static Path outlineOf(Iterable<GeoCoordData> coords) => outline([
        for (final c in coords) ...c.exteriorRings,
        for (final c in coords) ...c.interiorRings,
      ]);
}
