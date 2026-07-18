import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

enum FillMode {
  none,
  winnerOpaque,
  winnerOpacity,
  singleCandidateOpacity,
  winnerDotDensity,
  turnoutGray,
}

class MapStateStore {
  // Visible layers (default all)
  final visibleLayers = ListSignal<LayerType>([
    LayerType.state,
    LayerType.congressionalDistrict,
    LayerType.county,
    LayerType.precinct,
  ]);

  // Interactive Layer (one of the visible layers)
  final interactiveLayer = Signal<LayerType>(LayerType.precinct);

  // Fill Mode configuration
  final fillMode = Signal<FillMode>(FillMode.winnerOpaque);
  
  // Single Candidate for fillMode = singleCandidateOpacity
  final selectedCandidateId = Signal<int?>(null);

  // Inspector state
  final selectedCellId = Signal<int?>(null);
  final hoveredCellId = Signal<int?>(null);

  // Trigger to reset map view zoom/pan
  final resetViewTrigger = Signal<int>(0);

  /// Granularity order: finest first.
  static const _granularityOrder = [
    LayerType.precinct,
    LayerType.county,
    LayerType.congressionalDistrict,
    LayerType.state,
  ];

  void toggleLayerVisibility(LayerType type) {
    final layers = List<LayerType>.from(visibleLayers.value);
    if (layers.contains(type)) {
      layers.remove(type);
    } else {
      layers.add(type);
    }
    visibleLayers.value = layers;
    _autoSelectFinestInteractiveLayer();
  }

  /// Always pick the finest-grained visible layer as interactive.
  void _autoSelectFinestInteractiveLayer() {
    final visible = visibleLayers.value;
    for (final layer in _granularityOrder) {
      if (visible.contains(layer)) {
        if (interactiveLayer.value != layer) {
          interactiveLayer.value = layer;
          selectedCellId.value = null;
          hoveredCellId.value = null;
        }
        return;
      }
    }
  }

  void setInteractiveLayer(LayerType type) {
    if (visibleLayers.value.contains(type)) {
      interactiveLayer.value = type;
      // Clear selection when interactive layer changes
      selectedCellId.value = null;
      hoveredCellId.value = null;
    }
  }

  void setFillMode(FillMode mode) {
    fillMode.value = mode;
  }
}
