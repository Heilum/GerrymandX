import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

enum FillMode {
  none,
  winnerOpaque,
  winnerOpacity,
  singleCandidateOpacity,
  dotDensity,
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

  void toggleLayerVisibility(LayerType type) {
    final layers = List<LayerType>.from(visibleLayers.value);
    if (layers.contains(type)) {
      layers.remove(type);
    } else {
      layers.add(type);
    }
    visibleLayers.value = layers;
    
    // If the interactive layer was just hidden, fall back to another visible layer
    if (!visibleLayers.value.contains(interactiveLayer.value)) {
      if (visibleLayers.value.isNotEmpty) {
        interactiveLayer.value = visibleLayers.value.first;
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
