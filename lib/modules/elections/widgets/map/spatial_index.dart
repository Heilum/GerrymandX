import 'dart:math';
import 'package:flutter/painting.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

/// Grid-based spatial index for fast point-in-polygon hit testing.
/// Instead of checking all ~10k polygons, we only check the few
/// whose bounding boxes overlap the grid cell containing the query point.
class SpatialIndex {
  final int gridCols;
  final int gridRows;
  final Rect bounds;
  final double cellWidth;
  final double cellHeight;

  // grid[row * gridCols + col] = list of RenderableCell indices
  final List<List<int>> _grid;

  SpatialIndex._({
    required this.gridCols,
    required this.gridRows,
    required this.bounds,
    required this.cellWidth,
    required this.cellHeight,
    required List<List<int>> grid,
  }) : _grid = grid;

  /// Build a spatial index over [cells] within [bounds].
  /// [gridSize] controls resolution; 64 means 64×64 grid = 4096 buckets.
  factory SpatialIndex.build(List<RenderableCell> cells, Rect bounds, {int gridSize = 64}) {
    final cols = gridSize;
    final rows = gridSize;
    final cw = bounds.width / cols;
    final ch = bounds.height / rows;
    final grid = List<List<int>>.generate(cols * rows, (_) => []);

    for (int i = 0; i < cells.length; i++) {
      final b = cells[i].bounds;
      final minCol = ((b.left - bounds.left) / cw).floor().clamp(0, cols - 1);
      final maxCol = ((b.right - bounds.left) / cw).floor().clamp(0, cols - 1);
      final minRow = ((b.top - bounds.top) / ch).floor().clamp(0, rows - 1);
      final maxRow = ((b.bottom - bounds.top) / ch).floor().clamp(0, rows - 1);

      for (int r = minRow; r <= maxRow; r++) {
        for (int c = minCol; c <= maxCol; c++) {
          grid[r * cols + c].add(i);
        }
      }
    }

    return SpatialIndex._(
      gridCols: cols, gridRows: rows,
      bounds: bounds, cellWidth: cw, cellHeight: ch,
      grid: grid,
    );
  }

  /// Returns the index of the first cell whose path contains [point], or -1.
  int hitTest(Offset point, List<RenderableCell> cells) {
    if (!bounds.contains(point)) return -1;

    final col = ((point.dx - bounds.left) / cellWidth).floor().clamp(0, gridCols - 1);
    final row = ((point.dy - bounds.top) / cellHeight).floor().clamp(0, gridRows - 1);
    final bucket = _grid[row * gridCols + col];

    for (final idx in bucket) {
      if (idx >= cells.length) continue; // stale index after data reload
      final rCell = cells[idx];
      if (rCell.bounds.contains(point) && rCell.path.contains(point)) {
        return idx;
      }
    }
    return -1;
  }
}
