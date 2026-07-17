import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
        // ── Header: Layers left, Fill right ──
        Container(
          color: Theme.of(context).cardColor,
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Row(
            children: [
              // Left group: Layers
              const Text('Layers: ',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(width: 4),
              Expanded(
                child: Watch((context) {
                  return Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: LayerType.values.map((layer) {
                      final isVisible =
                          store.visibleLayers.value.contains(layer);
                      return FilterChip(
                        label: Text(layer.name,
                            style: const TextStyle(fontSize: 11)),
                        selected: isVisible,
                        onSelected: (_) => store.toggleLayerVisibility(layer),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      );
                    }).toList(),
                  );
                }),
              ),
              // Right group: Fill
              const SizedBox(width: 8),
              const Text('Fill: ',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(width: 4),
              Watch((context) {
                return DropdownButton<FillMode>(
                  value: store.fillMode.value,
                  isDense: true,
                  items: FillMode.values.map((mode) {
                    return DropdownMenuItem(
                        value: mode,
                        child: Text(mode.name,
                            style: const TextStyle(fontSize: 12)));
                  }).toList(),
                  onChanged: (mode) {
                    if (mode != null) store.setFillMode(mode);
                  },
                );
              }),
            ],
          ),
        ),
        const Divider(height: 1),
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
// No Watch wrapper; reads signals directly via
// subscriptions that only trigger setState when
// truly needed.
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
  SpatialIndex? _spatialIndex;
  Size _canvasSize = Size.zero;
  Timer? _hoverTimer;
  Offset? _pendingHoverPos;

  // ── Base map Picture cache ──
  ui.Picture? _cachedPicture;
  Size? _cachedSize;
  List<LayerType>? _cachedLayers;
  FillMode? _cachedFillMode;
  int? _cachedSingleCandidateId;
  bool _cachedLoading = true;

  // ── Signal subscriptions (disposed on dispose) ──
  final List<Function()> _disposers = [];

  @override
  void initState() {
    super.initState();
    _dataStore = context.read<MapDataStore>();
    _mapStore = context.read<MapStateStore>();

    // Subscribe to signals that require map redraw.
    // Each only calls setState — no heavy work happens here.
    _disposers.add(_dataStore.isLoadingData.subscribe((_) => _scheduleRebuild()));
    _disposers.add(_dataStore.overallBounds.subscribe((_) {
      _invalidateCache();
      _scheduleRebuild();
    }));
    _disposers.add(_dataStore.precinctVotes.subscribe((_) {
      _invalidateCache();
      _scheduleRebuild();
    }));
    _disposers.add(_mapStore.visibleLayers.subscribe((_) {
      _invalidateCache();
      _scheduleRebuild();
    }));
    _disposers.add(_mapStore.fillMode.subscribe((_) {
      _invalidateCache();
      _scheduleRebuild();
    }));
    _disposers.add(_mapStore.selectedCandidateId.subscribe((_) {
      _invalidateCache();
      _scheduleRebuild();
    }));
    _disposers.add(_mapStore.interactiveLayer.subscribe((_) {
      _rebuildSpatialIndex();
      _interactionNotifier.hoveredCellId = null;
      _interactionNotifier.selectedCellId = null;
      _scheduleRebuild();
    }));
  }

  bool _rebuildScheduled = false;
  void _scheduleRebuild() {
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  void _invalidateCache() {
    // Don't dispose here — the painter from the current frame may still
    // reference the old Picture. Let the GC reclaim it after replacement.
    _cachedPicture = null;
  }

  void _rebuildSpatialIndex() {
    final bounds = _dataStore.overallBounds.value;
    if (bounds == null) return;
    _spatialIndex = SpatialIndex.build(_getInteractiveCells(), bounds);
  }

  List<RenderableCell> _getInteractiveCells() {
    switch (_mapStore.interactiveLayer.value) {
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

  int? _hitTest(Offset localPos) {
    if (_spatialIndex == null || _canvasSize == Size.zero) return null;
    final bounds = _dataStore.overallBounds.value;
    if (bounds == null) return null;

    final t = MapTransform.fit(bounds, _canvasSize);
    final geoPoint = t.toGeo(localPos);

    final cells = _getInteractiveCells();
    final idx = _spatialIndex!.hitTest(geoPoint, cells);
    return idx >= 0 ? cells[idx].cell.id : null;
  }

  void _onHover(Offset localPos) {
    _pendingHoverPos = localPos;
    _hoverTimer ??= Timer(const Duration(milliseconds: 16), () {
      _hoverTimer = null;
      if (_pendingHoverPos != null) {
        final id = _hitTest(_pendingHoverPos!);
        _interactionNotifier.hoveredCellId = id;
        _mapStore.hoveredCellId.value = id;
      }
    });
  }

  void _onTap(Offset localPos) {
    final id = _hitTest(localPos);
    _interactionNotifier.selectedCellId = id;
    _mapStore.selectedCellId.value = id;
  }

  /// Record the base map as a ui.Picture if cache is stale.
  void _ensurePicture(Size size) {
    final layers = _mapStore.visibleLayers.value;
    final fillMode = _mapStore.fillMode.value;
    final singleId = _mapStore.selectedCandidateId.value;
    final loading = _dataStore.isLoadingData.value;

    final sameSize = _cachedSize == size;
    final sameLayers = _cachedLayers != null && _listEq(_cachedLayers!, layers);
    final sameFill = _cachedFillMode == fillMode;
    final sameCandidate = _cachedSingleCandidateId == singleId;
    final sameLoading = _cachedLoading == loading;

    if (_cachedPicture != null &&
        sameSize &&
        sameLayers &&
        sameFill &&
        sameCandidate &&
        sameLoading) {
      return; // cache hit
    }

    // Record new picture.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    if (!loading && _dataStore.overallBounds.value != null) {
      final painter = BaseMapPainter(
        dataStore: _dataStore,
        visibleLayers: layers,
        fillMode: fillMode,
        singleCandidateId: singleId,
      );
      painter.paint(canvas, size);
    }

    _cachedPicture = recorder.endRecording();
    _cachedSize = size;
    _cachedLayers = List.of(layers);
    _cachedFillMode = fillMode;
    _cachedSingleCandidateId = singleId;
    _cachedLoading = loading;
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _interactionNotifier.dispose();
    _cachedPicture?.dispose();
    for (final d in _disposers) {
      d();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = _dataStore.isLoadingData.value;
    final hasBounds = _dataStore.overallBounds.value != null;

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
    _spatialIndex ??= (() {
      _rebuildSpatialIndex();
      return _spatialIndex;
    })();

    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

        // Ensure the Picture is ready (cache hit = instant).
        _ensurePicture(_canvasSize);

        return Container(
          color: const Color(0xFF1A1A2E),
          child: MouseRegion(
            onHover: (event) => _onHover(event.localPosition),
            onExit: (_) {
              _interactionNotifier.hoveredCellId = null;
              _mapStore.hoveredCellId.value = null;
            },
            child: GestureDetector(
              onTapUp: (details) => _onTap(details.localPosition),
              child: Stack(
                children: [
                  // Layer 1: cached base map
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CachedPicturePainter(_cachedPicture),
                      size: _canvasSize,
                    ),
                  ),
                  // Layer 2: lightweight interaction overlay
                  Positioned.fill(
                    child: CustomPaint(
                      painter: InteractionOverlayPainter(
                        dataStore: _dataStore,
                        interactiveLayer: _mapStore.interactiveLayer.value,
                        notifier: _interactionNotifier,
                      ),
                      size: _canvasSize,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Ultra-lightweight painter: just draws a pre-recorded ui.Picture.
/// No path iteration, no color computation — just a single drawPicture call.
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

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
