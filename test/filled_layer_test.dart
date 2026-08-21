import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

/// Only one layer is filled; the rest draw borders. Which one that is has to
/// keep up with the layers being toggled, without overriding a deliberate
/// choice.
void main() {
  test('follows the finest visible layer until one is picked', () {
    final store = MapStateStore()
      ..setVisibleLayers([LayerType.county, LayerType.congressionalDistrict]);
    expect(store.filledLayer.value, LayerType.county);

    // Turning on a finer layer moves the fill, reproducing what the map showed
    // before the choice existed: the finest layer's fill covered the others'.
    store.setLayerVisible(LayerType.precinct, true);
    expect(store.filledLayer.value, LayerType.precinct);
  });

  test('a picked layer is not stolen by a finer one appearing', () {
    final store = MapStateStore()
      ..setVisibleLayers([LayerType.county, LayerType.congressionalDistrict])
      ..setFilledLayer(LayerType.congressionalDistrict);

    store.setLayerVisible(LayerType.precinct, true);

    expect(store.filledLayer.value, LayerType.congressionalDistrict);
  });

  test('hiding the picked layer falls back to the finest visible one', () {
    final store = MapStateStore()
      ..setVisibleLayers([
        LayerType.county,
        LayerType.congressionalDistrict,
        LayerType.precinct,
      ])
      ..setFilledLayer(LayerType.congressionalDistrict);

    store.setLayerVisible(LayerType.congressionalDistrict, false);
    expect(store.filledLayer.value, LayerType.precinct);

    // ...and having fallen back, it tracks again.
    store.setLayerVisible(LayerType.precinct, false);
    expect(store.filledLayer.value, LayerType.county);
  });

  test('cannot be pinned to a layer that is not visible', () {
    final store = MapStateStore()..setVisibleLayers([LayerType.county]);

    store.setFilledLayer(LayerType.precinct);

    expect(store.filledLayer.value, LayerType.county);
  });

  test('loading a new selection starts over', () {
    final store = MapStateStore()
      ..setVisibleLayers([LayerType.county, LayerType.precinct])
      ..setFilledLayer(LayerType.county);

    store.setVisibleLayers([LayerType.county, LayerType.precinct]);
    expect(store.filledLayer.value, LayerType.precinct);
  });
}
