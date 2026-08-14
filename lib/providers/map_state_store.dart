import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

enum FillMode {
  none,
  winnerOpaque,
  winnerOpacity,
  singleCandidateOpacity,
  winnerDotDensity,
  turnoutGray,

  /// One party, this election vs. another one: how much its vote share moved.
  singlePartyComparison,

  /// Two parties, this election vs. another one: how much the margin between
  /// them moved.
  twoPartyComparison,
}

extension FillModeInfo on FillMode {
  /// Compares the current election against another one, so it needs the same
  /// state to exist in at least two downloaded elections.
  bool get isComparison =>
      this == FillMode.singlePartyComparison ||
      this == FillMode.twoPartyComparison;

  /// Dart identifiers cannot start with a digit, hence the separate label.
  String get label =>
      this == FillMode.twoPartyComparison ? '2-partyComparison' : name;
}

class MapStateStore {
  // Visible layers (default state, congressionalDistrict, county)
  final visibleLayers = ListSignal<LayerType>([
    LayerType.state,
    LayerType.congressionalDistrict,
    LayerType.county,
  ]);

  // Interactive Layer (one of the visible layers)
  final interactiveLayer = Signal<LayerType>(LayerType.county);

  // Fill Mode configuration
  final fillMode = Signal<FillMode>(FillMode.winnerOpaque);
  
  // Single Candidate (UUID) for fillMode = singleCandidateOpacity
  final selectedCandidateId = Signal<String?>(null);

  /// Election folder the comparison fill modes measure against.
  final comparisonElectionFolder = Signal<String?>(null);

  /// Party ids **of the current election** for the comparison fill modes.
  /// Party ids are minted per election, so the other election is matched by
  /// party name, not by id.
  final comparisonPartyAId = Signal<String?>(null);
  final comparisonPartyBId = Signal<String?>(null);

  // Inspector state
  final selectedCellId = Signal<int?>(null);
  final hoveredCellId = Signal<int?>(null);

  // Trigger to reset map view zoom/pan
  final resetViewTrigger = Signal<int>(0);

  void resetSelection() {
    selectedCellId.value = null;
    hoveredCellId.value = null;
    selectedCandidateId.value = null;
    resetComparison();
  }

  /// The comparison target is tied to the state currently open — a different
  /// state (or election) has its own set of comparable elections.
  void resetComparison() {
    comparisonElectionFolder.value = null;
    comparisonPartyAId.value = null;
    comparisonPartyBId.value = null;
  }

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
