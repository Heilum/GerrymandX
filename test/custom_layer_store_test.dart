import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/providers/custom_layer_store.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/repositories/custom_layer_repository.dart';

/// Custom layers are edit-as-you-save: every store operation must land in the
/// repository in order, and a precinct must never sit in two groups at once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late CustomLayerRepository repo;
  late ElectionStore electionStore;
  late MapStateStore mapStore;
  late CustomLayerStore store;

  const tx = ElectionSubItem(name: 'Texas', isNational: false, dbName: 'TX.db');

  /// Lets the scope load and the write queue drain.
  Future<void> settle() => store.flush();

  setUp(() async {
    repo = await CustomLayerRepository.open(inMemoryDatabasePath);
    electionStore = ElectionStore();
    mapStore = MapStateStore();
    store = CustomLayerStore(
      electionStore,
      mapStore,
      openRepository: () async => repo,
    );
    electionStore.selectSubItem('2024', tx);
    await settle();
  });

  tearDown(() => repo.close());

  test('layers and groups round-trip through the repository', () async {
    final layer = (await store.createLayer(name: 'Plan A'))!;
    final g1 = (await store.addGroup(layer.id))!;
    final g2 = (await store.addGroup(layer.id, title: 'East'))!;
    expect(g1.title, 'G-1');

    store.assignPrecincts(layer.id, g1.id, [1, 2, 3]);
    store.assignPrecincts(layer.id, g2.id, [3, 4]); // 3 moves to g2
    store.setGroupColor(layer.id, g1.id, const Color(0xFF123456));
    store.renameLayer(layer.id, 'Plan A′');
    await settle();

    // In memory.
    final live = store.layerById(layer.id)!;
    expect(live.name, 'Plan A′');
    expect(live.groupById(g1.id)!.precinctIds, {1, 2});
    expect(live.groupById(g2.id)!.precinctIds, {3, 4});
    expect(live.groupOfPrecinct[3], g2.id);

    // On disk.
    final loaded = await repo.loadLayers('2024', 'TX.db');
    expect(loaded, hasLength(1));
    expect(loaded.first.name, 'Plan A′');
    final saved1 = loaded.first.groupById(g1.id)!;
    expect(saved1.precinctIds, {1, 2});
    expect(saved1.color.toARGB32(), 0xFF123456);
    expect(loaded.first.groupById(g2.id)!.precinctIds, {3, 4});
  });

  test('toggling a fully-contained cell removes it, otherwise adds it', () async {
    final layer = (await store.createLayer())!;
    final g = (await store.addGroup(layer.id))!;

    store.toggleCellInGroup(layer.id, g.id, [10, 11]);
    expect(store.layerById(layer.id)!.groupById(g.id)!.precinctIds, {10, 11});

    store.toggleCellInGroup(layer.id, g.id, [11, 12]); // partial → add
    expect(store.layerById(layer.id)!.groupById(g.id)!.precinctIds, {10, 11, 12});

    store.toggleCellInGroup(layer.id, g.id, [10, 11]); // contained → remove
    expect(store.layerById(layer.id)!.groupById(g.id)!.precinctIds, {12});
    await settle();
    expect(
      (await repo.loadLayers('2024', 'TX.db')).first.groupById(g.id)!.precinctIds,
      {12},
    );
  });

  test('deleting a group or layer cascades to its precincts', () async {
    final layer = (await store.createLayer())!;
    final g = (await store.addGroup(layer.id))!;
    store.assignPrecincts(layer.id, g.id, [1, 2]);
    store.deleteGroup(layer.id, g.id);
    await settle();
    expect((await repo.loadLayers('2024', 'TX.db')).first.groups, isEmpty);

    store.deleteLayer(layer.id);
    await settle();
    expect(await repo.loadLayers('2024', 'TX.db'), isEmpty);
    expect(store.layers.value, isEmpty);
  });

  test('showing a layer adds the custom layer to the visible layers', () async {
    final layer = (await store.createLayer())!;
    store.setActiveLayer(layer.id);
    expect(mapStore.visibleLayers.value, contains(LayerType.custom));
    expect(store.activeLayer.value?.id, layer.id);

    store.setActiveLayer(null);
    expect(mapStore.visibleLayers.value, isNot(contains(LayerType.custom)));
  });

  test('switching state re-scopes the layers and clears the active one', () async {
    final layer = (await store.createLayer(name: 'TX only'))!;
    store.setActiveLayer(layer.id);

    electionStore.selectSubItem(
      '2024',
      const ElectionSubItem(name: 'Ohio', isNational: false, dbName: 'OH.db'),
    );
    await settle();
    expect(store.activeLayerId.value, isNull);
    expect(store.layers.value, isEmpty);

    electionStore.selectSubItem('2024', tx);
    await settle();
    expect(store.layers.value.map((l) => l.name), ['TX only']);
  });

  test('deleting an election drops its layers only', () async {
    await store.createLayer(name: 'A');
    await repo.insertLayer('2020', 'TX.db', 'B', createdAt: 0);
    await store.deleteLayersOfElection('2020');
    expect(await repo.loadLayers('2020', 'TX.db'), isEmpty);
    expect((await repo.loadLayers('2024', 'TX.db')).map((l) => l.name), ['A']);
  });

  test('effects are disposed cleanly', () {
    // Sanity: signals from a previous test must not leak into this one.
    expect(store.layers.value, isEmpty);
    expect(untracked(() => store.activeLayer.value), isNull);
  });
}
