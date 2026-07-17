import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

/// Party colors — must match map_painter.dart constants.
const partyColors = <int, Color>{
  1: Color(0xFF2166AC), // Democrat
  2: Color(0xFFB2182B), // Republican
  3: Color(0xFFFFC107), // Libertarian
  4: Color(0xFF4CAF50), // Green
  5: Color(0xFF9E9E9E), // Independent
  6: Color(0xFF757575), // Write-In
  7: Color(0xFF616161), // Other
};
const defaultCellColor = Color(0xFF333333);

/// Holds the transformation from GeoJSON coordinates to canvas pixels.
class MapTransform {
  final double scale;
  final double offsetX;
  final double offsetY;

  const MapTransform({required this.scale, required this.offsetX, required this.offsetY});

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
    return Offset(
      (pixel.dx - offsetX) / scale,
      (pixel.dy - offsetY) / scale,
    );
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
  final int? singleCandidateId;

  /// Cached picture — avoids re-drawing 10k paths every frame.
  ui.Picture? _cachedPicture;
  Size? _cachedSize;

  // Cache keys to detect real changes.
  List<LayerType>? _prevLayers;
  FillMode? _prevFillMode;
  int? _prevSingleCandidateId;
  bool? _prevLoading;

  BaseMapPainter({
    required this.dataStore,
    required this.visibleLayers,
    required this.fillMode,
    this.singleCandidateId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (dataStore.isLoadingData.value || dataStore.overallBounds.value == null) {
      return;
    }

    final needsRepaint = _cachedPicture == null ||
        _cachedSize != size ||
        _prevLayers == null ||
        !_listEquals(_prevLayers!, visibleLayers) ||
        _prevFillMode != fillMode ||
        _prevSingleCandidateId != singleCandidateId ||
        _prevLoading != dataStore.isLoadingData.value;

    if (needsRepaint) {
      _cachedPicture = _recordPicture(size);
      _cachedSize = size;
      _prevLayers = List.of(visibleLayers);
      _prevFillMode = fillMode;
      _prevSingleCandidateId = singleCandidateId;
      _prevLoading = dataStore.isLoadingData.value;
    }

    canvas.drawPicture(_cachedPicture!);
  }

  ui.Picture _recordPicture(Size size) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    _paintMap(c, size);
    return recorder.endRecording();
  }

  void _paintMap(Canvas canvas, Size size) {
    final bounds = dataStore.overallBounds.value!;
    final t = MapTransform.fit(bounds, size);

    canvas.save();
    canvas.translate(t.offsetX, t.offsetY);
    canvas.scale(t.scale, t.scale);

    if (visibleLayers.contains(LayerType.state)) {
      _drawLayer(canvas, dataStore.states.value, LayerType.state, t.scale);
    }
    if (visibleLayers.contains(LayerType.congressionalDistrict)) {
      _drawLayer(canvas, dataStore.congressionalDistricts.value, LayerType.congressionalDistrict, t.scale);
    }
    if (visibleLayers.contains(LayerType.county)) {
      _drawLayer(canvas, dataStore.counties.value, LayerType.county, t.scale);
    }
    if (visibleLayers.contains(LayerType.precinct)) {
      _drawLayer(canvas, dataStore.precincts.value, LayerType.precinct, t.scale);
    }

    canvas.restore();
  }

  void _drawLayer(Canvas canvas, List<RenderableCell> cells, LayerType layerType, double mapScale) {
    double borderThickness;
    switch (layerType) {
      case LayerType.state:
        borderThickness = 3.0;
      case LayerType.congressionalDistrict:
      case LayerType.county:
        borderThickness = 1.5;
      case LayerType.precinct:
        borderThickness = 0.5;
    }

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderThickness / mapScale
      ..color = layerType == LayerType.precinct ? Colors.white24 : Colors.white54;

    final votes = dataStore.precinctVotes.value;
    final partyMap = dataStore.candidatePartyMap.value;

    for (final rCell in cells) {
      // FillMode.none: border only, no fill
      if (fillMode != FillMode.none) {
        Color fillColor;
        if (layerType == LayerType.precinct) {
          fillColor = _precinctFillColor(rCell.cell.id, votes, partyMap);
        } else {
          fillColor = Colors.transparent;
        }

        if (fillColor != Colors.transparent) {
          canvas.drawPath(rCell.path, Paint()
            ..color = fillColor
            ..style = PaintingStyle.fill);
        }
      }
      canvas.drawPath(rCell.path, borderPaint);
    }
  }

  Color _precinctFillColor(int precinctId, Map<int, PrecinctVoteSummary> votes, Map<int, int> partyMap) {
    final summary = votes[precinctId];
    if (summary == null || summary.totalVotes == 0) return defaultCellColor;

    switch (fillMode) {
      case FillMode.none:
        return Colors.transparent;

      case FillMode.winnerOpaque:
        final partyId = partyMap[summary.winnerCandidateId] ?? 0;
        return partyColors[partyId] ?? defaultCellColor;

      case FillMode.winnerOpacity:
        final partyId = partyMap[summary.winnerCandidateId] ?? 0;
        final baseColor = partyColors[partyId] ?? defaultCellColor;
        final margin = summary.winnerVotes / summary.totalVotes;
        return baseColor.withOpacity((margin * 1.5).clamp(0.3, 1.0));

      case FillMode.singleCandidateOpacity:
        if (singleCandidateId == null) return defaultCellColor;
        final candidateVotes = summary.candidateVotes[singleCandidateId] ?? 0;
        final share = candidateVotes / summary.totalVotes;
        final partyId = partyMap[singleCandidateId] ?? 0;
        final baseColor = partyColors[partyId] ?? defaultCellColor;
        return baseColor.withOpacity(share.clamp(0.05, 1.0));

      case FillMode.turnoutGray:
        final pop = summary.totalVotes * 1.8;
        final turnout = summary.totalVotes / pop;
        final gray = (turnout * 255).round().clamp(30, 240);
        return Color.fromARGB(255, gray, gray, gray);

      case FillMode.dotDensity:
        final partyId = partyMap[summary.winnerCandidateId] ?? 0;
        return (partyColors[partyId] ?? defaultCellColor).withOpacity(0.25);
    }
  }

  @override
  bool shouldRepaint(covariant BaseMapPainter oldDelegate) {
    return !_listEquals(oldDelegate.visibleLayers, visibleLayers) ||
        oldDelegate.fillMode != fillMode ||
        oldDelegate.singleCandidateId != singleCandidateId ||
        oldDelegate.dataStore.isLoadingData.value != dataStore.isLoadingData.value;
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
    if (_hoveredCellId != v) { _hoveredCellId = v; notifyListeners(); }
  }
  set selectedCellId(int? v) {
    if (_selectedCellId != v) { _selectedCellId = v; notifyListeners(); }
  }
}

class InteractionOverlayPainter extends CustomPainter {
  final MapDataStore dataStore;
  final LayerType interactiveLayer;
  final InteractionNotifier notifier;

  InteractionOverlayPainter({
    required this.dataStore,
    required this.interactiveLayer,
    required this.notifier,
  }) : super(repaint: notifier); // <-- repaint via Listenable, no widget rebuild

  @override
  void paint(Canvas canvas, Size size) {
    if (dataStore.overallBounds.value == null) return;

    final bounds = dataStore.overallBounds.value!;
    final t = MapTransform.fit(bounds, size);

    canvas.save();
    canvas.translate(t.offsetX, t.offsetY);
    canvas.scale(t.scale, t.scale);

    final cells = _getCells();
    final thickness = 2.0 / t.scale;

    // Draw hovered cell.
    if (notifier.hoveredCellId != null && notifier.hoveredCellId != notifier.selectedCellId) {
      final cell = _findCell(cells, notifier.hoveredCellId!);
      if (cell != null) {
        canvas.drawPath(cell.path, Paint()
          ..color = Colors.white.withOpacity(0.25)
          ..style = PaintingStyle.fill);
        canvas.drawPath(cell.path, Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness);
      }
    }

    // Draw selected cell.
    if (notifier.selectedCellId != null) {
      final cell = _findCell(cells, notifier.selectedCellId!);
      if (cell != null) {
        canvas.drawPath(cell.path, Paint()
          ..color = Colors.white.withOpacity(0.45)
          ..style = PaintingStyle.fill);
        canvas.drawPath(cell.path, Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness * 1.5);
      }
    }

    canvas.restore();
  }

  List<RenderableCell> _getCells() {
    switch (interactiveLayer) {
      case LayerType.state: return dataStore.states.value;
      case LayerType.county: return dataStore.counties.value;
      case LayerType.congressionalDistrict: return dataStore.congressionalDistricts.value;
      case LayerType.precinct: return dataStore.precincts.value;
    }
  }

  RenderableCell? _findCell(List<RenderableCell> cells, int id) {
    for (final c in cells) {
      if (c.cell.id == id) return c;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant InteractionOverlayPainter oldDelegate) {
    return oldDelegate.interactiveLayer != interactiveLayer;
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
