import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

/// Fallback for cells with no vote data or an unknown party.
const defaultCellColor = Color(0xFF333333);

/// Vote-share swing that saturates the comparison fill modes: ±10 points is
/// already a landslide-sized move between two elections.
const comparisonFullSwing = 0.10;

/// A party losing ground fades towards this instead of towards another party's
/// colour — "greyer the more it dropped".
const comparisonFadeColor = Color(0xFF616161);

/// Colour for a share (or margin) that moved by [delta] between two
/// elections: [gainColor] deepening with the gain, [lossColor] deepening with
/// the loss, white where nothing changed.
Color comparisonSwingColor(double delta, Color gainColor, Color lossColor) {
  final strength = (delta.abs() / comparisonFullSwing).clamp(0.0, 1.0);
  final target = delta >= 0 ? gainColor : lossColor;
  return Color.lerp(Colors.white, target, strength) ?? target;
}

/// Resolved inputs for the comparison fill modes, built once per repaint from
/// the map state. Null means the current selection is incomplete or invalid
/// (party missing from the other election, no election picked yet), and the
/// map falls back to neutral fills while the UI explains why.
class ComparisonSpec {
  /// Party name — ids are minted per election, names are the join key.
  final String partyAName;
  final Color partyAColor;

  /// Only set for [FillMode.twoPartyComparison].
  final String? partyBName;
  final Color? partyBColor;

  /// Bumped when the comparison data is reloaded, so cached Pictures drop.
  final int dataVersion;

  const ComparisonSpec({
    required this.partyAName,
    required this.partyAColor,
    this.partyBName,
    this.partyBColor,
    required this.dataVersion,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComparisonSpec &&
          partyAName == other.partyAName &&
          partyAColor == other.partyAColor &&
          partyBName == other.partyBName &&
          partyBColor == other.partyBColor &&
          dataVersion == other.dataVersion;

  @override
  int get hashCode => Object.hash(
        partyAName,
        partyAColor,
        partyBName,
        partyBColor,
        dataVersion,
      );
}

/// Holds the transformation from GeoJSON coordinates to canvas pixels.
class MapTransform {
  final double scale;
  final double offsetX;
  final double offsetY;

  const MapTransform({
    required this.scale,
    required this.offsetX,
    required this.offsetY,
  });

  factory MapTransform.fit(Rect geoBounds, Size canvasSize) {
    final scaleX = canvasSize.width / geoBounds.width;
    final scaleY = canvasSize.height / geoBounds.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final mapW = geoBounds.width * scale;
    final mapH = geoBounds.height * scale;
    return MapTransform(
      scale: scale,
      offsetX: (canvasSize.width - mapW) / 2 - geoBounds.left * scale,
      offsetY: (canvasSize.height - mapH) / 2 - geoBounds.top * scale,
    );
  }

  /// Convert canvas-local pixel position back to GeoJSON coordinate space.
  Offset toGeo(Offset pixel) {
    return Offset((pixel.dx - offsetX) / scale, (pixel.dy - offsetY) / scale);
  }
}

// ─────────────────────────────────────────────────
// BASE MAP PAINTER — cached as ui.Picture, only repaints
// when data / layers / fillMode change.
// ─────────────────────────────────────────────────
class BaseMapPainter extends CustomPainter {
  final MapDataStore dataStore;
  final List<LayerType> visibleLayers;
  final FillMode fillMode;
  final String? singleCandidateId;
  final ComparisonSpec? comparisonSpec;
  final double interactiveScale;
  final bool drawFill;
  final bool drawBorder;

  BaseMapPainter({
    required this.dataStore,
    required this.visibleLayers,
    required this.fillMode,
    this.singleCandidateId,
    this.comparisonSpec,
    required this.interactiveScale,
    this.drawFill = true,
    this.drawBorder = true,
  });

  /// Fills that are interpolated up from white need darker borders to stay
  /// readable.
  bool get _hasLightFills =>
      fillMode == FillMode.singleCandidateOpacity || fillMode.isComparison;

  @override
  void paint(Canvas canvas, Size size) {
    if (dataStore.isLoadingData.value ||
        dataStore.overallBounds.value == null) {
      return;
    }
    _paintMap(canvas, size);
  }

  void _paintMap(Canvas canvas, Size size) {
    final bounds = dataStore.overallBounds.value!;
    final t = MapTransform.fit(bounds, size);

    canvas.save();
    canvas.translate(t.offsetX, t.offsetY);
    canvas.scale(t.scale, t.scale);

    if (visibleLayers.contains(LayerType.state)) {
      _drawLayer(
        canvas,
        dataStore.states.value,
        LayerType.state,
        t.scale,
        size,
        t,
      );
    }
    if (visibleLayers.contains(LayerType.county)) {
      _drawLayer(
        canvas,
        dataStore.counties.value,
        LayerType.county,
        t.scale,
        size,
        t,
      );
    }
    if (visibleLayers.contains(LayerType.congressionalDistrict)) {
      _drawLayer(
        canvas,
        dataStore.congressionalDistricts.value,
        LayerType.congressionalDistrict,
        t.scale,
        size,
        t,
      );
    }
    if (visibleLayers.contains(LayerType.precinct)) {
      _drawLayer(
        canvas,
        dataStore.precincts.value,
        LayerType.precinct,
        t.scale,
        size,
        t,
      );
    }

    canvas.restore();
  }

  void _drawLayer(
    Canvas canvas,
    List<RenderableCell> cells,
    LayerType layerType,
    double mapScale,
    Size canvasSize,
    MapTransform t,
  ) {
    double borderThickness;
    Color borderColor;
    switch (layerType) {
      case LayerType.state:
        borderThickness = 3.0;
        borderColor = _hasLightFills ? Colors.grey[700]! : Colors.white54;
      case LayerType.congressionalDistrict:
        borderThickness = 0.5;
        borderColor = const Color(0xffffcc00);
      case LayerType.county:
        borderThickness = 0.5;
        borderColor = _hasLightFills ? Colors.grey[600]! : Colors.white54;
      case LayerType.precinct:
        borderThickness = 0.25;
        borderColor = _hasLightFills ? Colors.grey[800]! : Colors.white24;
    }

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderThickness / (mapScale * interactiveScale)
      ..color = borderColor;

    final fillPaint = Paint()..style = PaintingStyle.fill;

    // The canvas is currently transformed so that geo coordinates map directly to pixels.
    // So the visible bounds in geo-coordinates is exactly the canvas rect transformed back.
    final geoVisibleRect = Rect.fromLTRB(
      -t.offsetX / t.scale,
      -t.offsetY / t.scale,
      (canvasSize.width - t.offsetX) / t.scale,
      (canvasSize.height - t.offsetY) / t.scale,
    );

    for (final rCell in cells) {
      // Viewport culling (P0)
      if (!geoVisibleRect.overlaps(rCell.bounds)) {
        continue;
      }

      // FillMode.none: border only, no fill
      if (drawFill && fillMode != FillMode.none) {
        if (fillMode == FillMode.winnerDotDensity) {
          final summary = dataStore.aggregateVotesForRegion(layerType, rCell.cell.id);
          if (summary != null && summary.winnerVotes > 0) {
            fillPaint.color = _getMarginColor(summary);

            double basePixelRadius;
            switch (layerType) {
              case LayerType.state:
                basePixelRadius = summary.winnerVotes * 0.000005;
              case LayerType.congressionalDistrict:
                basePixelRadius = summary.winnerVotes * 0.00005;
              case LayerType.county:
                basePixelRadius = summary.winnerVotes * 0.0001;
              case LayerType.precinct:
                basePixelRadius = summary.winnerVotes * 0.003;
            }
            
            // Clamp base radius so it's visible but not overlapping everything at 1x zoom
            basePixelRadius = basePixelRadius.clamp(2.0, 40.0);
            
            // Apply zoom level effect: grows with square root of zoom
            final currentPixelRadius = basePixelRadius * math.pow(interactiveScale, 0.5);
            
            // Convert to geographic radius for drawCircle
            final radius = currentPixelRadius / (mapScale * interactiveScale);
            final center = rCell.cell.centerLon != null && rCell.cell.centerLat != null
                ? Offset(rCell.cell.centerLon!, -rCell.cell.centerLat!)
                : rCell.bounds.center;
            canvas.drawCircle(center, radius, fillPaint);
          }
        } else {
          Color fillColor = _getFillColor(layerType, rCell.cell);
          if (fillColor != Colors.transparent) {
            fillPaint.color = fillColor;
            canvas.drawPath(rCell.path, fillPaint);
          }
        }
      }
      if (drawBorder) {
        canvas.drawPath(rCell.exteriorPath, borderPaint);
      }
    }
  }

  Color _getStrengthColor(double share, String? candidateId) {
    final baseColor = dataStore.partyColorForCandidate(candidateId) ?? defaultCellColor;
    // Map vote share to color strength:
    // 50% share -> strength 0.0 (White/Neutral)
    // >= 75% share -> strength 1.0 (Solid Party Color)
    final strength = ((share - 0.5) * 4.0).clamp(0.0, 1.0);
    
    // Interpolate between a neutral light color and the party color
    return Color.lerp(Colors.white, baseColor, strength) ?? baseColor;
  }

  Color _getMarginColor(PrecinctVoteSummary summary) {
    final share = summary.totalVotes > 0 ? summary.winnerVotes / summary.totalVotes : 0.5;
    return _getStrengthColor(share, summary.winnerCandidateId);
  }

  /// Falls back to [defaultCellColor] for cells whose region has no
  /// counterpart in the comparison election — a county that was renamed, a
  /// district that redistricting removed.
  Color _comparisonFillFor(
    LayerType layerType,
    GeoCell cell,
    PrecinctVoteSummary summary,
  ) {
    final spec = comparisonSpec;
    if (spec == null) return defaultCellColor;

    final baselineA = dataStore.comparisonShareFor(
      layerType,
      cell.name,
      spec.partyAName,
    );
    if (baselineA == null) return defaultCellColor;
    final currentA = dataStore.partyShareIn(summary, spec.partyAName);

    if (fillMode == FillMode.singlePartyComparison) {
      // Gained share → the party's colour, deeper the bigger the gain.
      // Lost share → greyer the bigger the loss.
      return comparisonSwingColor(
        currentA - baselineA,
        spec.partyAColor,
        comparisonFadeColor,
      );
    }

    // Two parties: how the A-minus-B margin itself moved.
    final partyBName = spec.partyBName;
    final partyBColor = spec.partyBColor;
    if (partyBName == null || partyBColor == null) return defaultCellColor;

    final baselineB = dataStore.comparisonShareFor(
      layerType,
      cell.name,
      partyBName,
    );
    if (baselineB == null) return defaultCellColor;
    final currentB = dataStore.partyShareIn(summary, partyBName);

    final marginSwing = (currentA - currentB) - (baselineA - baselineB);
    return comparisonSwingColor(marginSwing, spec.partyAColor, partyBColor);
  }

  Color _getFillColor(LayerType layerType, GeoCell cell) {
    if (fillMode == FillMode.none) return Colors.transparent;

    final summary = dataStore.aggregateVotesForRegion(layerType, cell.id);
    if (summary == null || summary.totalVotes == 0) return defaultCellColor;

    switch (fillMode) {
      case FillMode.none:
        return Colors.transparent;

      case FillMode.winnerOpaque:
        return dataStore.partyColorForCandidate(summary.winnerCandidateId) ??
            defaultCellColor;

      case FillMode.winnerOpacity:
        return _getMarginColor(summary);

      case FillMode.singleCandidateOpacity:
        if (singleCandidateId == null) return defaultCellColor;
        final candidateVotes = summary.candidateVotes[singleCandidateId] ?? 0;
        final share = summary.totalVotes > 0 ? candidateVotes / summary.totalVotes : 0.0;
        return _getStrengthColor(share, singleCandidateId);

      case FillMode.turnoutGray:
        final pop = summary.totalVotes * 1.8;
        final turnout = summary.totalVotes / pop;
        final gray = (turnout * 255).round().clamp(30, 240);
        return Color.fromARGB(255, gray, gray, gray);

      case FillMode.winnerDotDensity:
        return Colors.transparent;

      case FillMode.singlePartyComparison:
      case FillMode.twoPartyComparison:
        return _comparisonFillFor(layerType, cell, summary);
    }
  }

  @override
  bool shouldRepaint(covariant BaseMapPainter oldDelegate) {
    return !_listEquals(oldDelegate.visibleLayers, visibleLayers) ||
        oldDelegate.fillMode != fillMode ||
        oldDelegate.singleCandidateId != singleCandidateId ||
        oldDelegate.comparisonSpec != comparisonSpec ||
        oldDelegate.dataStore.isLoadingData.value !=
            dataStore.isLoadingData.value;
  }
}

// ─────────────────────────────────────────────────
// INTERACTION OVERLAY PAINTER — only draws 1-2 polygons
// (the hovered and/or selected cell). Driven by a
// ChangeNotifier so it repaints without rebuilding the widget.
// ─────────────────────────────────────────────────
class InteractionNotifier extends ChangeNotifier {
  int? _hoveredCellId;
  int? _selectedCellId;

  int? get hoveredCellId => _hoveredCellId;
  int? get selectedCellId => _selectedCellId;

  set hoveredCellId(int? v) {
    if (_hoveredCellId != v) {
      _hoveredCellId = v;
      notifyListeners();
    }
  }

  set selectedCellId(int? v) {
    if (_selectedCellId != v) {
      _selectedCellId = v;
      notifyListeners();
    }
  }
}

class InteractionOverlayPainter extends CustomPainter {
  final MapDataStore dataStore;
  final LayerType interactiveLayer;
  final InteractionNotifier notifier;
  final Map<int, RenderableCell> cellIndex;

  InteractionOverlayPainter({
    required this.dataStore,
    required this.interactiveLayer,
    required this.notifier,
    required this.cellIndex,
  }) : super(
         repaint: notifier,
       ); // <-- repaint via Listenable, no widget rebuild

  @override
  void paint(Canvas canvas, Size size) {
    if (dataStore.overallBounds.value == null) return;

    final bounds = dataStore.overallBounds.value!;
    final t = MapTransform.fit(bounds, size);

    canvas.save();
    canvas.translate(t.offsetX, t.offsetY);
    canvas.scale(t.scale, t.scale);

    final thickness = 2.0 / t.scale;

    // Pre-allocate paint objects.
    final hoverFillPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;
    final selectedFillPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.fill;

    // Draw hovered cell.
    if (notifier.hoveredCellId != null &&
        notifier.hoveredCellId != notifier.selectedCellId) {
      final cell = cellIndex[notifier.hoveredCellId!];
      if (cell != null) {
        canvas.drawPath(cell.path, hoverFillPaint);
      }
    }

    // Draw selected cell.
    if (notifier.selectedCellId != null) {
      final cell = cellIndex[notifier.selectedCellId!];
      if (cell != null) {
        canvas.drawPath(cell.path, selectedFillPaint);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant InteractionOverlayPainter oldDelegate) {
    return oldDelegate.interactiveLayer != interactiveLayer ||
        oldDelegate.cellIndex != cellIndex;
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
