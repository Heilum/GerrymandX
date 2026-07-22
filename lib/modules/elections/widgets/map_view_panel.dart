import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/spatial_index.dart';


class MapViewPanel extends StatefulWidget {
  const MapViewPanel({super.key});

  @override
  State<MapViewPanel> createState() => _MapViewPanelState();
}

class _MapViewPanelState extends State<MapViewPanel> {
  @override
  Widget build(BuildContext context) {
    final store = context.read<MapStateStore>();

    return Column(
      children: [

        // ── Map Canvas ──
        Expanded(
          child: RepaintBoundary(
            child: _MapCanvas(),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// _MapCanvas — fully stateful, owns ALL caches.
// Uses Watch inside build() to auto-rebuild when
// signals change. Per-layer Picture cache lives
// in State and survives across Watch rebuilds.
// ─────────────────────────────────────────────
class _MapCanvas extends StatefulWidget {
  const _MapCanvas();

  @override
  State<_MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<_MapCanvas> {
  // ── Stores (injected once) ──
  late final MapDataStore _dataStore;
  late final MapStateStore _mapStore;

  // ── Interaction ──
  final InteractionNotifier _interactionNotifier = InteractionNotifier();
  final TransformationController _transformController =
      TransformationController();
  SpatialIndex? _spatialIndex;
  Size _canvasSize = Size.zero;
  Timer? _hoverTimer;
  Offset? _pendingHoverPos;

  // ── Per-layer Picture cache (P3: dirty tracking) ──
  final Map<LayerType, _LayerPictures> _layerPictures = {};
  final Map<LayerType, _LayerCacheKey> _layerCacheKeys = {};
  ui.Picture? _compositePicture;
  Size? _cachedSize;
  List<LayerType>? _cachedVisibleLayers;

  LayerType? _lastInteractiveLayer;
  int? _lastSelectedCellId;
  Map<int, RenderableCell>? _lastCellIndex;
  EffectCleanup? _resetEffect;
  Timer? _zoomDebounceTimer;
  double _currentZoomScale = 1.0;

  @override
  void initState() {
    super.initState();
    _dataStore = context.read<MapDataStore>();
    _mapStore = context.read<MapStateStore>();
    
    _resetEffect = effect(() {
      final trigger = _mapStore.resetViewTrigger.value;
      if (trigger > 0) {
        _transformController.value = Matrix4.identity();
      }
    });

    _transformController.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    final scale = _transformController.value.getMaxScaleOnAxis();
    if ((scale - _currentZoomScale).abs() > 0.05) {
      _zoomDebounceTimer?.cancel();
      _zoomDebounceTimer = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        setState(() {
          _currentZoomScale = scale;
        });
      });
    }
  }

  void _rebuildSpatialIndex(LayerType layer) {
    final bounds = _dataStore.overallBounds.value;
    if (bounds == null) return;
    _spatialIndex = SpatialIndex.build(_getInteractiveCells(layer), bounds);
  }

  List<RenderableCell> _getInteractiveCells(LayerType layer) {
    switch (layer) {
      case LayerType.state:
        return _dataStore.states.value;
      case LayerType.county:
        return _dataStore.counties.value;
      case LayerType.congressionalDistrict:
        return _dataStore.congressionalDistricts.value;
      case LayerType.precinct:
        return _dataStore.precincts.value;
    }
  }

  // ── Hit-test: accounts for InteractiveViewer transform ──
  int? _hitTest(Offset localPos, LayerType layer) {
    if (_spatialIndex == null || _canvasSize == Size.zero) return null;
    final bounds = _dataStore.overallBounds.value;
    if (bounds == null) return null;

    // Use transformation matrix to convert screen hit to canvas local coordinate
    final t = _transformController.value.clone();
    t.invert();
    final canvasLocal = MatrixUtils.transformPoint(t, localPos);

    final mapT = MapTransform.fit(bounds, _canvasSize);
    final geoPoint = mapT.toGeo(canvasLocal);

    final cells = _getInteractiveCells(layer);
    final idx = _spatialIndex!.hitTest(geoPoint, cells);
    return idx >= 0 ? cells[idx].cell.id : null;
  }

  void _onHover(Offset localPos, LayerType layer) {
    _pendingHoverPos = localPos;
    _hoverTimer ??= Timer(const Duration(milliseconds: 16), () {
      _hoverTimer = null;
      if (_pendingHoverPos != null) {
        final id = _hitTest(_pendingHoverPos!, layer);
        _interactionNotifier.hoveredCellId = id;
        _mapStore.hoveredCellId.value = id;
      }
    });
  }

  void _onTap(Offset localPos, LayerType layer) {
    final id = _hitTest(localPos, layer);
    _interactionNotifier.selectedCellId = id;
    _mapStore.selectedCellId.value = id;
  }


  // ── P3: Per-layer Picture caching ──
  _LayerPictures _recordLayerPictures(
    Size size,
    LayerType layerType,
    FillMode fillMode,
    int? singleCandidateId,
    double zoomScale,
  ) {
    // Record fill
    final fillRecorder = ui.PictureRecorder();
    if (_dataStore.overallBounds.value != null) {
      final fillPainter = BaseMapPainter(
        dataStore: _dataStore,
        visibleLayers: [layerType],
        fillMode: fillMode,
        singleCandidateId: singleCandidateId,
        interactiveScale: zoomScale,
        drawFill: true,
        drawBorder: false,
      );
      fillPainter.paint(Canvas(fillRecorder), size);
    }
    final fillPic = fillRecorder.endRecording();

    // Record border
    final borderRecorder = ui.PictureRecorder();
    if (_dataStore.overallBounds.value != null) {
      final borderPainter = BaseMapPainter(
        dataStore: _dataStore,
        visibleLayers: [layerType],
        fillMode: fillMode,
        singleCandidateId: singleCandidateId,
        interactiveScale: zoomScale,
        drawFill: false,
        drawBorder: true,
      );
      borderPainter.paint(Canvas(borderRecorder), size);
    }
    final borderPic = borderRecorder.endRecording();

    return _LayerPictures(fillPic, borderPic);
  }

  void _ensurePicture(
    Size size,
    List<LayerType> layers,
    FillMode fillMode,
    int? singleCandidateId,
  ) {
    bool compositeNeeded = false;

    // Check each visible layer's cache.
    for (final layer in layers) {
      final key = _LayerCacheKey(size: size, fillMode: fillMode, singleCandidateId: singleCandidateId, zoomScale: _currentZoomScale);
      final existingKey = _layerCacheKeys[layer];
      
      if (_layerPictures[layer] == null || existingKey != key) {
        // Cache miss for this layer — re-record both fill and border.
        _layerPictures[layer]?.dispose();
        _layerPictures[layer] = _recordLayerPictures(size, layer, fillMode, singleCandidateId, _currentZoomScale);
        _layerCacheKeys[layer] = key;
        compositeNeeded = true;
      }
    }

    // Remove pictures for layers that are no longer visible.
    final removedLayers = _layerPictures.keys.where((l) => !layers.contains(l)).toList();
    if (removedLayers.isNotEmpty) {
      for (final l in removedLayers) {
        _layerPictures.remove(l);
        _layerCacheKeys.remove(l);
      }
      compositeNeeded = true;
    }

    // Check if visible layers order changed.
    if (!compositeNeeded && _cachedVisibleLayers != null && !_listEq(_cachedVisibleLayers!, layers)) {
      compositeNeeded = true;
    }

    if (!compositeNeeded && _compositePicture != null && _cachedSize == size) {
      return; // Full cache hit.
    }

    // Composite all visible layer Pictures into one final Picture.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Draw in correct z-order: state → county → CD → precinct.
    const drawOrder = [
      LayerType.state,
      LayerType.county,
      LayerType.congressionalDistrict,
      LayerType.precinct,
    ];
    
    // First Pass: Draw all fills
    for (final layer in drawOrder) {
      if (layers.contains(layer) && _layerPictures.containsKey(layer)) {
        canvas.drawPicture(_layerPictures[layer]!.fill);
      }
    }
    
    // Second Pass: Draw all borders
    for (final layer in drawOrder) {
      if (layers.contains(layer) && _layerPictures.containsKey(layer)) {
        canvas.drawPicture(_layerPictures[layer]!.border);
      }
    }
    _compositePicture = recorder.endRecording();
    _cachedSize = size;
    _cachedVisibleLayers = List.of(layers);
  }

  /// Handle scroll-wheel zoom on macOS.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final direction = event.scrollDelta.dy > 0 ? -1.0 : 1.0;
      const zoomFactor = 0.1;
      final currentScale =
          _transformController.value.getMaxScaleOnAxis();
      final newScale =
          (currentScale * (1.0 + direction * zoomFactor)).clamp(0.5, 30.0);
      final scaleDelta = newScale / currentScale;

      // Scale centered on pointer position.
      final focalPoint = event.localPosition;
      final matrix = _transformController.value.clone();
      final focalInChild = matrix.clone()..invert();
      final focalLocal =
          MatrixUtils.transformPoint(focalInChild, focalPoint);

      matrix.translate(focalLocal.dx, focalLocal.dy);
      matrix.scale(scaleDelta, scaleDelta);
      matrix.translate(-focalLocal.dx, -focalLocal.dy);

      _transformController.value = matrix;
    }
  }

  @override
  void dispose() {
    _zoomDebounceTimer?.cancel();
    _transformController.removeListener(_onTransformChanged);
    _resetEffect?.call();
    _hoverTimer?.cancel();
    _interactionNotifier.dispose();
    _transformController.dispose();
    _compositePicture?.dispose();
    for (final p in _layerPictures.values) {
      p.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final isLoading = _dataStore.isLoadingData.value;
      final hasBounds = _dataStore.overallBounds.value != null;
      final layers = _mapStore.visibleLayers.value;
      final fillMode = _mapStore.fillMode.value;
      final singleCandidateId = _mapStore.selectedCandidateId.value;
      final interactiveLayer = _mapStore.interactiveLayer.value;
      final selectedCellId = _mapStore.selectedCellId.value;
      // Read cellIndex for O(1) lookup in overlay painter.
      final cellIdx = _dataStore.cellIndex.value;

      // Detect interactive layer or data changes → rebuild spatial index.
      final dataChanged = !identical(_lastCellIndex, cellIdx);
      if (_lastInteractiveLayer != interactiveLayer || dataChanged) {
        _lastInteractiveLayer = interactiveLayer;
        _lastCellIndex = cellIdx;
        _rebuildSpatialIndex(interactiveLayer);
        _interactionNotifier.hoveredCellId = null;
        _interactionNotifier.selectedCellId = null;
      }



      if (isLoading) {
        return Container(
          color: const Color(0xFF1A1A2E),
          child: const Center(child: CircularProgressIndicator()),
        );
      }
      if (!hasBounds) {
        return Container(
          color: const Color(0xFF1A1A2E),
          child: const Center(
            child: Text('Select an election to view the map',
                style: TextStyle(color: Colors.white54, fontSize: 16)),
          ),
        );
      }

      // Build spatial index on first paint if not yet built.
      if (_spatialIndex == null) {
        _rebuildSpatialIndex(interactiveLayer);
      }

      return LayoutBuilder(
        builder: (context, constraints) {
          _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

          // P3: Per-layer Picture cache.
          _ensurePicture(_canvasSize, layers, fillMode, singleCandidateId);

          return Container(
            color: const Color(0xFF1A1A2E),
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: MouseRegion(
                onHover: (event) =>
                    _onHover(event.localPosition, interactiveLayer),
                onExit: (_) {
                  _interactionNotifier.hoveredCellId = null;
                  _mapStore.hoveredCellId.value = null;
                },
                child: GestureDetector(
                  onTapUp: (details) =>
                      _onTap(details.localPosition, interactiveLayer),
                  child: InteractiveViewer(
                    transformationController: _transformController,
                    minScale: 0.5,
                    maxScale: 30.0,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    panEnabled: true,
                    scaleEnabled: true,
                    child: SizedBox(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      child: Stack(
                        children: [
                          // Layer 1: cached composite base map
                          Positioned.fill(
                            child: CustomPaint(
                              painter:
                                  _CachedPicturePainter(_compositePicture),
                              size: _canvasSize,
                            ),
                          ),
                          // Layer 2: lightweight interaction overlay
                          Positioned.fill(
                            child: CustomPaint(
                              painter: InteractionOverlayPainter(
                                dataStore: _dataStore,
                                interactiveLayer: interactiveLayer,
                                notifier: _interactionNotifier,
                                cellIndex: cellIdx,
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
        },
      );
    });
  }
}

/// Ultra-lightweight painter: just draws a pre-recorded ui.Picture.
class _CachedPicturePainter extends CustomPainter {
  final ui.Picture? picture;

  _CachedPicturePainter(this.picture);

  @override
  void paint(Canvas canvas, Size size) {
    if (picture != null) {
      canvas.drawPicture(picture!);
    }
  }

  @override
  bool shouldRepaint(covariant _CachedPicturePainter old) {
    return old.picture != picture;
  }
}

/// Cache key for a single layer's Picture.
class _LayerPictures {
  final ui.Picture fill;
  final ui.Picture border;

  _LayerPictures(this.fill, this.border);

  void dispose() {
    fill.dispose();
    border.dispose();
  }
}

class _LayerCacheKey {
  final Size size;
  final FillMode fillMode;
  final int? singleCandidateId;
  final double zoomScale;

  _LayerCacheKey({required this.size, required this.fillMode, required this.singleCandidateId, required this.zoomScale});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _LayerCacheKey &&
          size == other.size &&
          fillMode == other.fillMode &&
          singleCandidateId == other.singleCandidateId &&
          zoomScale == other.zoomScale;

  @override
  int get hashCode => Object.hash(size, fillMode, singleCandidateId, zoomScale);
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
