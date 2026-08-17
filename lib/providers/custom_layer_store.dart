import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/models/custom_layer.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/repositories/custom_layer_repository.dart';

/// Custom layers of the state currently open, plus which one the main map is
/// showing.
///
/// Every edit is applied to the in-memory signals first (so the UI reacts at
/// once) and written through to the repository in the same call order. There
/// is no separate "save": editing *is* saving.
class CustomLayerStore {
  final ElectionStore electionStore;
  final MapStateStore mapStateStore;

  /// Layers of the current `<election>/<dbName>` scope, oldest first.
  final layers = ListSignal<CustomLayer>([]);

  /// Layer shown on the main map, or null for none. Only one custom layer is
  /// ever displayed at a time.
  final activeLayerId = Signal<int?>(null);

  late final ReadonlySignal<CustomLayer?> activeLayer = computed(() {
    final id = activeLayerId.value;
    if (id == null) return null;
    return layers.value.where((l) => l.id == id).firstOrNull;
  });

  final isLoading = Signal<bool>(false);

  final Future<CustomLayerRepository> Function() _openRepository;
  Future<CustomLayerRepository>? _repoFuture;

  /// Writes are chained so they reach the database in the order the user made
  /// them, even though callers do not await them.
  Future<void> _writeQueue = Future.value();

  String? _election;
  String? _dbName;
  int _loadToken = 0;

  /// The scope load in flight, if any. Creating things before it completes
  /// would let the load's snapshot overwrite them, so creators await it.
  Future<void> _pendingLoad = Future.value();

  CustomLayerStore(
    this.electionStore,
    this.mapStateStore, {
    Future<CustomLayerRepository> Function()? openRepository,
  }) : _openRepository = openRepository ?? _openDefaultRepository {
    effect(() {
      final election = electionStore.selectedElectionFolder.value;
      final subItem = electionStore.selectedSubItem.value;
      final dbName = subItem == null || subItem.isNational ? null : subItem.dbName;
      _setScope(election, dbName);
    });
  }

  static Future<CustomLayerRepository> _openDefaultRepository() async =>
      CustomLayerRepository.open(await DatabaseHelper.instance.customLayerDbPath);

  Future<CustomLayerRepository> get _repo =>
      _repoFuture ??= _openRepository();

  CustomLayer? layerById(int id) =>
      layers.value.where((l) => l.id == id).firstOrNull;

  // ── Scope ──

  void _setScope(String? election, String? dbName) {
    if (election == _election && dbName == _dbName) return;
    _election = election;
    _dbName = dbName;
    setActiveLayer(null);
    if (election == null || dbName == null || dbName.isEmpty) {
      layers.value = [];
      return;
    }
    _pendingLoad = _load(election, dbName);
  }

  Future<void> _load(String election, String dbName) async {
    final token = ++_loadToken;
    isLoading.value = true;
    try {
      // Wait for pending writes so a scope switched away from and straight
      // back to reads its own edits.
      await _writeQueue;
      final loaded = await (await _repo).loadLayers(election, dbName);
      if (token != _loadToken) return;
      layers.value = loaded;
    } catch (e, stack) {
      debugPrint('Error loading custom layers for $election/$dbName: $e\n$stack');
      if (token == _loadToken) layers.value = [];
    } finally {
      if (token == _loadToken) isLoading.value = false;
    }
  }

  /// Completes once the scope load and every write issued so far are done.
  Future<void> flush() async {
    await _pendingLoad;
    await _writeQueue;
  }

  /// Re-reads the current scope from disk.
  Future<void> reload() async {
    final election = _election, dbName = _dbName;
    if (election == null || dbName == null) return;
    _pendingLoad = _load(election, dbName);
    await _pendingLoad;
  }

  // ── Display ──

  /// Shows [layerId] on the main map (null hides the custom layer). Keeps the
  /// map's visible-layer list in step so the painter and layer chips agree.
  void setActiveLayer(int? layerId) {
    activeLayerId.value = layerId;
    mapStateStore.setLayerVisible(LayerType.custom, layerId != null);
  }

  // ── Layers ──

  Future<CustomLayer?> createLayer({String? name}) async {
    await _pendingLoad;
    final election = _election, dbName = _dbName;
    if (election == null || dbName == null) return null;
    final layerName = name ?? _defaultLayerName();
    final id = await _write((repo) => repo.insertLayer(
          election,
          dbName,
          layerName,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
    if (id == null) return null;
    final layer = CustomLayer(
      id: id,
      election: election,
      dbName: dbName,
      name: layerName,
      groups: const [],
    );
    layers.value = [...layers.value, layer];
    return layer;
  }

  String _defaultLayerName() {
    final taken = layers.value.map((l) => l.name).toSet();
    var n = layers.value.length + 1;
    while (taken.contains('Custom layer $n')) {
      n++;
    }
    return 'Custom layer $n';
  }

  void renameLayer(int layerId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _updateLayer(layerId, (l) => l.copyWith(name: trimmed));
    _write((repo) => repo.renameLayer(layerId, trimmed));
  }

  void deleteLayer(int layerId) {
    if (activeLayerId.value == layerId) setActiveLayer(null);
    layers.value = layers.value.where((l) => l.id != layerId).toList();
    _write((repo) => repo.deleteLayer(layerId));
  }

  /// Drops the layers of an election that is being removed. Their precinct
  /// ids only meant something in that election's databases.
  Future<void> deleteLayersOfElection(String election) async {
    if (election == _election) {
      setActiveLayer(null);
      layers.value = [];
    }
    await _write((repo) => repo.deleteLayersOfElection(election));
  }

  // ── Groups ──

  Future<GroupCell?> addGroup(int layerId, {String? title, Color? color}) async {
    await _pendingLoad;
    final layer = layerById(layerId);
    if (layer == null) return null;
    final groupTitle = title?.trim().isNotEmpty == true
        ? title!.trim()
        : defaultGroupTitle(layer);
    final groupColor =
        color ?? GroupCell.nextColor(layer.groups.map((g) => g.color));
    final sortOrder =
        layer.groups.isEmpty ? 0 : layer.groups.last.sortOrder + 1;
    final id = await _write(
        (repo) => repo.insertGroup(layerId, groupTitle, groupColor, sortOrder));
    if (id == null) return null;
    final group = GroupCell(
      id: id,
      layerId: layerId,
      title: groupTitle,
      color: groupColor,
      sortOrder: sortOrder,
      precinctIds: const {},
    );
    _updateLayer(layerId, (l) => l.copyWith(groups: [...l.groups, group]));
    return group;
  }

  /// `G-1`, `G-2`, … skipping titles already in use.
  static String defaultGroupTitle(CustomLayer layer) {
    final taken = layer.groups.map((g) => g.title).toSet();
    var n = layer.groups.length + 1;
    while (taken.contains('G-$n')) {
      n++;
    }
    return 'G-$n';
  }

  void renameGroup(int layerId, int groupId, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    _updateGroup(layerId, groupId, (g) => g.copyWith(title: trimmed));
    _write((repo) => repo.updateGroup(groupId, title: trimmed));
  }

  void setGroupColor(int layerId, int groupId, Color color) {
    _updateGroup(layerId, groupId, (g) => g.copyWith(color: color));
    _write((repo) => repo.updateGroup(groupId, color: color));
  }

  void deleteGroup(int layerId, int groupId) {
    _updateLayer(
      layerId,
      (l) => l.copyWith(groups: l.groups.where((g) => g.id != groupId).toList()),
    );
    _write((repo) => repo.deleteGroup(groupId));
  }

  // ── Membership ──

  /// Adds [precinctIds] to [groupId]. A precinct belongs to one group of a
  /// layer at most, so they are taken out of any other group first.
  void assignPrecincts(int layerId, int groupId, Iterable<int> precinctIds) {
    final ids = precinctIds.toSet();
    if (ids.isEmpty) return;
    _updateLayer(layerId, (l) {
      final groups = l.groups.map((g) {
        if (g.id == groupId) {
          return g.copyWith(precinctIds: {...g.precinctIds, ...ids});
        }
        if (g.precinctIds.any(ids.contains)) {
          return g.copyWith(precinctIds: g.precinctIds.difference(ids));
        }
        return g;
      }).toList();
      return l.copyWith(groups: groups);
    });
    _write((repo) => repo.assignPrecincts(layerId, groupId, ids));
  }

  void removePrecincts(int layerId, int groupId, Iterable<int> precinctIds) {
    final ids = precinctIds.toSet();
    if (ids.isEmpty) return;
    _updateGroup(
      layerId,
      groupId,
      (g) => g.copyWith(precinctIds: g.precinctIds.difference(ids)),
    );
    _write((repo) => repo.removePrecincts(groupId, ids));
  }

  /// One click on a cell of a built-in layer: if the group already holds
  /// every one of the cell's precincts they are removed, otherwise they are
  /// all added.
  void toggleCellInGroup(int layerId, int groupId, Iterable<int> precinctIds) {
    final group = layerById(layerId)?.groupById(groupId);
    if (group == null) return;
    final ids = precinctIds.toSet();
    if (ids.isEmpty) return;
    if (group.precinctIds.containsAll(ids)) {
      removePrecincts(layerId, groupId, ids);
    } else {
      assignPrecincts(layerId, groupId, ids);
    }
  }

  // ── Internals ──

  void _updateLayer(int layerId, CustomLayer Function(CustomLayer) update) {
    layers.value = [
      for (final l in layers.value) l.id == layerId ? update(l) : l,
    ];
  }

  void _updateGroup(
    int layerId,
    int groupId,
    GroupCell Function(GroupCell) update,
  ) {
    _updateLayer(
      layerId,
      (l) => l.copyWith(
        groups: [for (final g in l.groups) g.id == groupId ? update(g) : g],
      ),
    );
  }

  /// Runs [op] after every earlier write. Returns null (and logs) on failure
  /// so one bad write does not wedge the queue.
  Future<T?> _write<T>(Future<T> Function(CustomLayerRepository) op) {
    final result = _writeQueue.then((_) async {
      try {
        return await op(await _repo);
      } catch (e, stack) {
        debugPrint('Custom layer write failed: $e\n$stack');
        return null;
      }
    });
    _writeQueue = result.then((_) {});
    return result;
  }
}
