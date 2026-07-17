import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/spatial_index.dart';

class MapViewPanel extends StatelessWidget {
  const MapViewPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.read<MapStateStore>();

    return Column(
      children: [
        // ── Header Config ──
        Container(
          color: Theme.of(context).cardColor,
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Layers: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(width: 4),
                  Watch((context) {
                    return Wrap(
                      spacing: 4,
                      children: LayerType.values.map((layer) {
                        final isVisible = store.visibleLayers.value.contains(layer);
                        return FilterChip(
                          label: Text(layer.name, style: const TextStyle(fontSize: 11)),
                          selected: isVisible,
                          onSelected: (_) => store.toggleLayerVisibility(layer),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        );
                      }).toList(),
                    );
                  }),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Fill: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(width: 4),
                  Watch((context) {
                    return DropdownButton<FillMode>(
                      value: store.fillMode.value,
                      isDense: true,
                      items: FillMode.values.map((mode) {
                        return DropdownMenuItem(value: mode, child: Text(mode.name, style: const TextStyle(fontSize: 12)));
                      }).toList(),
                      onChanged: (mode) {
                        if (mode != null) store.setFillMode(mode);
                      },
                    );
                  }),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── Map Canvas ──
        Expanded(
          child: Watch((context) {
            // This Watch only rebuilds on *structural* changes:
            // loading state, layer toggles, fill mode — NOT hover/selection.
            final dataStore = context.read<MapDataStore>();
            final isLoading = dataStore.isLoadingData.value;
            final hasBounds = dataStore.overallBounds.value != null;
            final layers = store.visibleLayers.value;
            final fillMode = store.fillMode.value;
            final singleCandidateId = store.selectedCandidateId.value;
            final interactiveLayer = store.interactiveLayer.value;

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

            return _MapCanvas(
              dataStore: dataStore,
              mapStateStore: store,
              visibleLayers: List.of(layers),
              fillMode: fillMode,
              singleCandidateId: singleCandidateId,
              interactiveLayer: interactiveLayer,
            );
          }),
        ),
      ],
    );
  }
}

/// Stateful widget that owns the InteractionNotifier and SpatialIndex.
/// Hover/selection updates go through the notifier — NO widget rebuild.
class _MapCanvas extends StatefulWidget {
  final MapDataStore dataStore;
  final MapStateStore mapStateStore;
  final List<LayerType> visibleLayers;
  final FillMode fillMode;
  final int? singleCandidateId;
  final LayerType interactiveLayer;

  const _MapCanvas({
    required this.dataStore,
    required this.mapStateStore,
    required this.visibleLayers,
    required this.fillMode,
    this.singleCandidateId,
    required this.interactiveLayer,
  });

  @override
  State<_MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<_MapCanvas> {
  final InteractionNotifier _interactionNotifier = InteractionNotifier();
  SpatialIndex? _spatialIndex;
  Size _canvasSize = Size.zero;

  // Throttle hover: process at most once per 16ms (~60fps).
  Timer? _hoverTimer;
  Offset? _pendingHoverPos;

  @override
  void initState() {
    super.initState();
    _buildSpatialIndex();
  }

  @override
  void didUpdateWidget(covariant _MapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interactiveLayer != widget.interactiveLayer) {
      _buildSpatialIndex();
      _interactionNotifier.hoveredCellId = null;
      _interactionNotifier.selectedCellId = null;
      // Defer signal writes to after build phase to avoid SignalEffectException.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.mapStateStore.hoveredCellId.value = null;
        widget.mapStateStore.selectedCellId.value = null;
      });
    }
  }

  void _buildSpatialIndex() {
    final bounds = widget.dataStore.overallBounds.value;
    if (bounds == null) return;

    final cells = _getInteractiveCells();
    _spatialIndex = SpatialIndex.build(cells, bounds);
  }

  List<RenderableCell> _getInteractiveCells() {
    switch (widget.interactiveLayer) {
      case LayerType.state: return widget.dataStore.states.value;
      case LayerType.county: return widget.dataStore.counties.value;
      case LayerType.congressionalDistrict: return widget.dataStore.congressionalDistricts.value;
      case LayerType.precinct: return widget.dataStore.precincts.value;
    }
  }

  int? _hitTest(Offset localPos) {
    if (_spatialIndex == null || _canvasSize == Size.zero) return null;
    final bounds = widget.dataStore.overallBounds.value;
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
        widget.mapStateStore.hoveredCellId.value = id;
      }
    });
  }

  void _onTap(Offset localPos) {
    final id = _hitTest(localPos);
    _interactionNotifier.selectedCellId = id;
    widget.mapStateStore.selectedCellId.value = id;
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _interactionNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

        return Container(
          color: const Color(0xFF1A1A2E),
          child: MouseRegion(
            onHover: (event) => _onHover(event.localPosition),
            onExit: (_) {
              _interactionNotifier.hoveredCellId = null;
              widget.mapStateStore.hoveredCellId.value = null;
            },
            child: GestureDetector(
              onTapUp: (details) => _onTap(details.localPosition),
              child: Stack(
                children: [
                  // Layer 1: Base map (cached as ui.Picture)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: BaseMapPainter(
                        dataStore: widget.dataStore,
                        visibleLayers: widget.visibleLayers,
                        fillMode: widget.fillMode,
                        singleCandidateId: widget.singleCandidateId,
                      ),
                      size: _canvasSize,
                    ),
                  ),
                  // Layer 2: Interaction overlay (draws 1-2 polygons via Listenable)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: InteractionOverlayPainter(
                        dataStore: widget.dataStore,
                        interactiveLayer: widget.interactiveLayer,
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
