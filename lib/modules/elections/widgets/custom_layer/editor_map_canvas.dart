import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'package:gerrymanderx/models/custom_layer.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_zoom.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/spatial_index.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

/// The map inside the custom-layer editor.
///
/// Its fill never follows the vote-based fill modes: precincts of the group
/// being edited are painted in that group's colour, precincts of the layer's
/// other groups in theirs (dimmed, so a precinct that moves between groups is
/// seen to move), and everything else shows borders only. Clicking a cell of
/// the interactive layer hands its precincts to [onCellTap].
class EditorMapCanvas extends StatefulWidget {
  const EditorMapCanvas({
    super.key,
    required this.layer,
    required this.selectedGroupId,
    required this.visibleLayers,
    required this.interactiveLayer,
    required this.onCellTap,
  });

  final CustomLayer layer;
  final int? selectedGroupId;
  final List<LayerType> visibleLayers;
  final LayerType interactiveLayer;
  final void Function(LayerType layer, int cellId) onCellTap;

  @override
  State<EditorMapCanvas> createState() => _EditorMapCanvasState();
}

class _EditorMapCanvasState extends State<EditorMapCanvas> {
  static const _background = Color(0xFF1A1A2E);
  static const _selectedAlpha = 0.85;
  static const _otherAlpha = 0.35;

  late final MapDataStore _dataStore;

  final _transform = TransformationController();
  final _interaction = InteractionNotifier();

  final Map<LayerType, SpatialIndex> _indexes = {};
  int _indexesDataVersion = -1;

  Size _canvasSize = Size.zero;
  Timer? _hoverTimer;
  Offset? _pendingHoverPos;
  Timer? _zoomDebounce;
  double _zoomScale = 1.0;

  ui.Picture? _borderPicture;
  _BorderKey? _borderKey;
  ui.Picture? _fillPicture;
  _FillKey? _fillKey;

  @override
  void initState() {
    super.initState();
    _dataStore = context.read<MapDataStore>();
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _zoomDebounce?.cancel();
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    _interaction.dispose();
    _borderPicture?.dispose();
    _fillPicture?.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final scale = _transform.value.getMaxScaleOnAxis();
    if ((scale - _zoomScale).abs() > 0.05) {
      _zoomDebounce?.cancel();
      _zoomDebounce = Timer(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _zoomScale = scale);
      });
    }
  }

  // ── Hit testing ──

  List<RenderableCell> _cellsOf(LayerType layer) {
    switch (layer) {
      case LayerType.county:
        return _dataStore.counties.value;
      case LayerType.congressionalDistrict:
        return _dataStore.congressionalDistricts.value;
      case LayerType.precinct:
        return _dataStore.precincts.value;
      case LayerType.state:
        return _dataStore.states.value;
      case LayerType.custom:
        return _dataStore.customCells.value;
    }
  }

  SpatialIndex? _indexFor(LayerType layer) {
    final bounds = _dataStore.overallBounds.value;
    if (bounds == null) return null;
    final version = _dataStore.dataVersion.value;
    if (_indexesDataVersion != version) {
      _indexes.clear();
      _indexesDataVersion = version;
    }
    return _indexes[layer] ??= SpatialIndex.build(_cellsOf(layer), bounds);
  }

  int? _hitTest(Offset localPos) {
    final bounds = _dataStore.overallBounds.value;
    if (bounds == null || _canvasSize == Size.zero) return null;
    final layer = widget.interactiveLayer;
    final index = _indexFor(layer);
    if (index == null) return null;

    final inverse = _transform.value.clone()..invert();
    final canvasLocal = MatrixUtils.transformPoint(inverse, localPos);
    final geo = MapTransform.fit(bounds, _canvasSize).toGeo(canvasLocal);

    final cells = _cellsOf(layer);
    final idx = index.hitTest(geo, cells);
    return idx >= 0 ? cells[idx].cell.id : null;
  }

  void _onHover(Offset localPos) {
    _pendingHoverPos = localPos;
    _hoverTimer ??= Timer(const Duration(milliseconds: 16), () {
      _hoverTimer = null;
      final pos = _pendingHoverPos;
      if (pos != null) _interaction.hoveredCellId = _hitTest(pos);
    });
  }

  void _onTap(Offset localPos) {
    final id = _hitTest(localPos);
    if (id != null) widget.onCellTap(widget.interactiveLayer, id);
  }

  // ── Recording ──

  void _ensureBorderPicture(Size size, double zoomBucket, int dataVersion) {
    final key = _BorderKey(size, List.of(widget.visibleLayers), zoomBucket, dataVersion);
    if (_borderPicture != null && _borderKey == key) return;
    _borderPicture?.dispose();
    final recorder = ui.PictureRecorder();
    BaseMapPainter(
      dataStore: _dataStore,
      visibleLayers: widget.visibleLayers,
      fillMode: FillMode.none,
      interactiveScale: zoomBucket,
      drawFill: false,
      drawBorder: true,
    ).paint(Canvas(recorder), size);
    _borderPicture = recorder.endRecording();
    _borderKey = key;
  }

  void _ensureFillPicture(Size size, int dataVersion) {
    final key = _FillKey(size, widget.layer, widget.selectedGroupId, dataVersion);
    if (_fillPicture != null && _fillKey == key) return;
    _fillPicture?.dispose();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = _dataStore.overallBounds.value;
    final precinctIdx = _dataStore.cellIndex.value[LayerType.precinct];
    if (bounds != null && precinctIdx != null) {
      final t = MapTransform.fit(bounds, size);
      canvas.save();
      canvas.translate(t.offsetX, t.offsetY);
      canvas.scale(t.scale, t.scale);
      final paint = Paint()..style = PaintingStyle.fill;
      // Selected group last so it wins where a stale overlap might exist.
      final groups = [
        ...widget.layer.groups.where((g) => g.id != widget.selectedGroupId),
        ...widget.layer.groups.where((g) => g.id == widget.selectedGroupId),
      ];
      for (final g in groups) {
        final selected = g.id == widget.selectedGroupId;
        paint.color = g.color.withValues(
          alpha: selected ? _selectedAlpha : _otherAlpha,
        );
        // One path per group: filling precincts one by one leaves faint
        // anti-aliasing seams along every shared border.
        final combined = Path()..fillType = PathFillType.evenOdd;
        for (final p in g.precinctIds) {
          final rc = precinctIdx[p];
          if (rc != null) combined.addPath(rc.path, Offset.zero);
        }
        canvas.drawPath(combined, paint);
      }
      canvas.restore();
    }
    _fillPicture = recorder.endRecording();
    _fillKey = key;
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final isLoading = _dataStore.isLoadingData.value;
      final bounds = _dataStore.overallBounds.value;
      final dataVersion = _dataStore.dataVersion.value;
      final interactiveCells =
          _dataStore.cellIndex.value[widget.interactiveLayer] ??
              const <int, RenderableCell>{};

      if (isLoading || bounds == null) {
        return Container(
          color: _background,
          child: Center(
            child: isLoading
                ? const CircularProgressIndicator()
                : const Text('No map loaded',
                    style: TextStyle(color: Colors.white54)),
          ),
        );
      }

      return LayoutBuilder(builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        _ensureBorderPicture(
            _canvasSize, MapZoom.bucketFor(_zoomScale), dataVersion);
        _ensureFillPicture(_canvasSize, dataVersion);
        final maxScale = MapZoom.maxScaleFor(bounds, _canvasSize);

        return Container(
          color: _background,
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                MapZoom.applyScroll(_transform, event, maxScale: maxScale);
              }
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onHover: (e) => _onHover(e.localPosition),
              onExit: (_) => _interaction.hoveredCellId = null,
              child: GestureDetector(
                onTapUp: (d) => _onTap(d.localPosition),
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: MapZoom.minScale,
                  maxScale: maxScale,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _PicturePainter(_fillPicture),
                            size: _canvasSize,
                          ),
                        ),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _PicturePainter(_borderPicture),
                            size: _canvasSize,
                          ),
                        ),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: InteractionOverlayPainter(
                              dataStore: _dataStore,
                              interactiveLayer: widget.interactiveLayer,
                              notifier: _interaction,
                              cellIndex: interactiveCells,
                            ),
                            size: _canvasSize,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      });
    });
  }
}

class _PicturePainter extends CustomPainter {
  _PicturePainter(this.picture);
  final ui.Picture? picture;

  @override
  void paint(Canvas canvas, Size size) {
    if (picture != null) canvas.drawPicture(picture!);
  }

  @override
  bool shouldRepaint(covariant _PicturePainter old) => old.picture != picture;
}

class _BorderKey {
  _BorderKey(this.size, this.layers, this.zoomBucket, this.dataVersion);
  final Size size;
  final List<LayerType> layers;
  final double zoomBucket;
  final int dataVersion;

  @override
  bool operator ==(Object other) =>
      other is _BorderKey &&
      size == other.size &&
      zoomBucket == other.zoomBucket &&
      dataVersion == other.dataVersion &&
      layers.length == other.layers.length &&
      Iterable.generate(layers.length).every((i) => layers[i] == other.layers[i]);

  @override
  int get hashCode => Object.hash(size, zoomBucket, dataVersion, Object.hashAll(layers));
}

/// The layer object is replaced on every edit, so identity is the version.
class _FillKey {
  _FillKey(this.size, this.layer, this.selectedGroupId, this.dataVersion);
  final Size size;
  final CustomLayer layer;
  final int? selectedGroupId;
  final int dataVersion;

  @override
  bool operator ==(Object other) =>
      other is _FillKey &&
      size == other.size &&
      identical(layer, other.layer) &&
      selectedGroupId == other.selectedGroupId &&
      dataVersion == other.dataVersion;

  @override
  int get hashCode =>
      Object.hash(size, identityHashCode(layer), selectedGroupId, dataVersion);
}
