import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:flutter/painting.dart';
import 'package:gerrymanderx/models/custom_layer.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/repositories/election_repository.dart';
import 'package:gerrymanderx/core/utils/geojson_parser.dart';
import 'package:gerrymanderx/core/utils/map_projection.dart';
import 'package:gerrymanderx/core/utils/region_outline.dart';
import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/spatial_index.dart';
import 'package:gerrymanderx/providers/custom_layer_store.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class RenderableCell {
  final GeoCell cell;
  final Path path;
  final Path exteriorPath;
  final Rect bounds;

  RenderableCell({
    required this.cell,
    required this.path,
    required this.exteriorPath,
    required this.bounds,
  });
}

/// Aggregated vote totals for a precinct.
class PrecinctVoteSummary {
  final int totalVotes;
  final String? winnerCandidateId;
  final int winnerVotes;
  final Map<String, int> candidateVotes; // candidateId (UUID) -> votes
  final int population;

  PrecinctVoteSummary({
    required this.totalVotes,
    required this.winnerCandidateId,
    required this.winnerVotes,
    required this.candidateVotes,
    this.population = 0,
  });
}

/// Who took each US House seat of a state, worked out from the statewide
/// candidate totals: every district's seat goes to its best-placed candidate.
class HouseSeatSummary {
  final int totalSeats;

  /// Party name (`DEM`, `REP`, …) → seats won. Parties with no seat are absent.
  final Map<String, int> seatsByParty;

  const HouseSeatSummary({required this.totalSeats, required this.seatsByParty});

  /// Districts are read off the candidates' `district` field, which is how a
  /// year-folder database says which race each House candidate ran in.
  /// Candidates without a district (a legacy manifest) contribute no seat.
  static HouseSeatSummary compute({
    required Iterable<Candidate> candidates,
    required Map<String, String> candidatePartyMap,
    required Map<String, Party> parties,
    required Map<String, int> candidateVotes,
  }) {
    final byDistrict = <String, List<Candidate>>{};
    for (final c in candidates) {
      final district = c.district;
      if (district == null || district.isEmpty) continue;
      byDistrict.putIfAbsent(district, () => []).add(c);
    }

    final seats = <String, int>{};
    for (final runners in byDistrict.values) {
      Candidate? winner;
      var best = -1;
      for (final c in runners) {
        final votes = candidateVotes[c.id] ?? 0;
        if (votes > best) {
          best = votes;
          winner = c;
        }
      }
      // A district whose votes have not been counted yet is still a seat,
      // just one nobody holds.
      if (winner == null || best <= 0) continue;
      final partyName = parties[candidatePartyMap[winner.id]]?.name ?? '?';
      seats[partyName] = (seats[partyName] ?? 0) + 1;
    }
    return HouseSeatSummary(totalSeats: byDistrict.length, seatsByParty: seats);
  }
}

/// A comparison-election precinct reduced to what re-aggregation needs: where
/// it is, and how it voted.
///
/// Kept for as long as a comparison is active so that user-defined groups can
/// be re-aggregated as they are edited, without holding on to the geometry
/// those points came from.
class BaselinePoint {
  /// Centre in the geometry's own coordinates (longitude, -latitude).
  final Offset centre;
  final RegionPartyVotes votes;

  const BaselinePoint(this.centre, this.votes);
}

/// Party-level totals for one region of the comparison election.
///
/// Only party aggregates are kept: the other election's candidates are
/// different people, so a candidate-level breakdown would not line up with
/// the current one.
class RegionPartyVotes {
  final int totalVotes;

  /// {partyName: votes} — names, because party ids are minted per election.
  final Map<String, int> votesByParty;

  const RegionPartyVotes({required this.totalVotes, required this.votesByParty});

  double shareOf(String partyName) =>
      totalVotes > 0 ? (votesByParty[partyName] ?? 0) / totalVotes : 0.0;
}

/// How a group cell decomposes into the built-in regions: the counties and
/// districts it holds in full, and the precincts left over.
class GroupComposition {
  final List<GeoCell> wholeCounties;
  final List<GeoCell> wholeDistricts;

  /// Member precincts not covered by any whole county or whole district.
  final int remainingPrecincts;
  final int totalPrecincts;

  const GroupComposition({
    required this.wholeCounties,
    required this.wholeDistricts,
    required this.remainingPrecincts,
    required this.totalPrecincts,
  });

  static const empty = GroupComposition(
    wholeCounties: [],
    wholeDistricts: [],
    remainingPrecincts: 0,
    totalPrecincts: 0,
  );
}

class MapDataStore {
  final ElectionStore electionStore;
  final MapStateStore mapStateStore;
  final CustomLayerStore? customLayerStore;
  final ElectionRepository _repo = ElectionRepository();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  // Layer cell data
  final states = ListSignal<RenderableCell>([]);
  final counties = ListSignal<RenderableCell>([]);
  final congressionalDistricts = ListSignal<RenderableCell>([]);
  final precincts = ListSignal<RenderableCell>([]);

  /// O(1) cell lookup by ID, per layer type. Counties, congressional districts
  /// and precincts each number from 1 in their own state DB, so ids are only
  /// unique within a layer — never flatten this into a single map.
  final cellIndex = Signal<Map<LayerType, Map<int, RenderableCell>>>({});

  RenderableCell? cellAt(LayerType layer, int id) => layer == LayerType.custom
      ? customCellIndex.value[id]
      : cellIndex.value[layer]?[id];

  // ── Custom layer (group cells of the active CustomLayer) ──
  //
  // Kept apart from [cellIndex]: replacing that signal is what tells the map
  // a new state was loaded (and resets pan/zoom), which an edit to a group
  // must not do.

  /// One renderable per group cell of the active custom layer.
  final customCells = ListSignal<RenderableCell>([]);
  final customCellIndex = Signal<Map<int, RenderableCell>>({});

  /// {groupId: [precinctId, ...]} — same role as [countyPrecincts].
  final customPrecincts = Signal<Map<int, List<int>>>({});
  final customGroupColors = Signal<Map<int, Color>>({});

  /// {precinctId: groupId} for the active custom layer.
  final customGroupOfPrecinct = Signal<Map<int, int>>({});

  /// Bumped whenever the custom renderables are rebuilt, for painter caches
  /// and spatial indexes.
  final customVersion = Signal<int>(0);

  Timer? _customRebuildTimer;

  /// Geometry cache per group: rebuilding a group's outline costs a pass over
  /// its precinct vertices, so groups whose precinct set did not change reuse
  /// their previous renderable.
  final Map<int, ({Set<int> precinctIds, String title, RenderableCell cell})>
      _groupCellCache = {};
  int _groupCellCacheVersion = -1;

  /// Combined bounding box of all loaded geometries, in map coordinates.
  final overallBounds = Signal<Rect?>(null);

  /// Longitude/latitude → map coordinates for the loaded selection. Fitted
  /// to the selection's extent when it loads, and applied to everything
  /// drawn with it: the paths, the stored centres, and the comparison
  /// election's geometry. Not a signal: it changes only together with the
  /// geometry, which [dataVersion] already announces.
  MapProjection projection = MapProjection.identity;

  /// The conic for [cells], fitted to the extent of their stored centres.
  @visibleForTesting
  static MapProjection projectionForTest(Iterable<GeoCell> cells) =>
      _projectionFor(cells);

  static MapProjection _projectionFor(Iterable<GeoCell> cells) =>
      MapProjection.forPoints([
        for (final c in cells)
          if (c.centerLat != null && c.centerLon != null)
            (lat: c.centerLat!, lon: c.centerLon!),
      ]);

  /// Signal to track data loading state
  final isLoadingData = Signal<bool>(false);

  /// Bumped whenever the loaded geometry/vote data is replaced. Consumers that
  /// cache rendered output must include this in their cache key.
  final dataVersion = Signal<int>(0);

  /// {precinctId: PrecinctVoteSummary}
  final precinctVotes = Signal<Map<int, PrecinctVoteSummary>>({});

  /// {candidateId: partyId}
  final candidatePartyMap = Signal<Map<String, String>>({});

  /// {partyName: [candidateId, ...]} for the current election. Party *names*
  /// are what the comparison modes join on, since ids differ per election.
  final candidateIdsByPartyName = Signal<Map<String, List<String>>>({});

  /// All candidates for this election, from the election manifest.
  final candidates = ListSignal<Candidate>([]);

  /// All parties for this election, keyed by party id.
  final parties = Signal<Map<String, Party>>({});

  /// Contests the loaded state database holds — up to President, US Senate,
  /// US House and Governor for a year folder; a legacy database is one
  /// presidential contest.
  final availableElections = ListSignal<ElectionContest>([]);

  /// The contest whose candidates, parties and votes are loaded.
  final activeElection = Signal<ElectionContest?>(null);

  /// The office whose contest is a set of district seats rather than one
  /// statewide race.
  static const houseOffice = 'US House';

  /// Precincts of the "Only See" district, or null when no district is being
  /// looked at on its own (none picked, or the contest is not a House race).
  late final ReadonlySignal<Set<int>?> focusPrecincts = computed(() {
    final districtId = mapStateStore.focusDistrictId.value;
    if (districtId == null) return null;
    if (activeElection.value?.office != houseOffice) return null;
    return (cdPrecincts.value[districtId] ?? const <int>[]).toSet();
  });

  /// True when the loaded state database carries its contests in an
  /// `elections` table (year folders); false for a legacy database.
  bool _newSchema = false;
  String? _loadedDbName;

  /// Party colour for a candidate, falling back to the neutral cell colour.
  Color? partyColorForCandidate(String? candidateId) {
    if (candidateId == null) return null;
    final partyId = candidatePartyMap.value[candidateId];
    return partyId == null ? null : parties.value[partyId]?.color;
  }

  /// Region → precinct mappings for aggregating non-precinct cells
  /// {countyId: [precinctId, ...]}
  final countyPrecincts = Signal<Map<int, List<int>>>({});
  /// {cdId: [precinctId, ...]}
  final cdPrecincts = Signal<Map<int, List<int>>>({});

  // ── Cross-election comparison (FillMode.singlePartyComparison / twoPartyComparison) ──

  /// The comparison election's votes re-aggregated onto the **current** map's
  /// counties and districts, keyed by layer and by the current region's id.
  ///
  /// Regions are never joined by name or id across elections: ids are minted
  /// per election, and a name can denote different ground — Texas redrew every
  /// congressional district after the 2020 census, so its "District 13" covers
  /// different counties in each election. Instead the other election's
  /// precinct votes are summed into whichever current region contains them,
  /// which answers "how would that election have gone under this map".
  final comparisonRegionVotes =
      Signal<Map<LayerType, Map<int, RegionPartyVotes>>>({});

  /// Comparison-election party totals for the **current** election's
  /// precincts, keyed by current precinct id.
  ///
  /// Precincts are matched the other way round — see
  /// [_matchPrecinctsToComparison].
  final comparisonPrecinctVotes = Signal<Map<int, RegionPartyVotes>>({});

  final isLoadingComparison = Signal<bool>(false);

  /// Bumped whenever the comparison data is replaced, for painter cache keys.
  final comparisonVersion = Signal<int>(0);

  String? _lastLoadedFolder;
  ElectionSubItem? _lastLoadedSubItem;
  bool _loading = false;

  /// Selection requested while a load was still running. Databases are big
  /// enough that clicking during a load is normal, and dropping the click
  /// leaves the map showing something the sidebar disagrees with.
  (String, ElectionSubItem)? _pendingSelection;

  /// `<comparisonElection>/<stateDb>` currently loaded (or loading), null when
  /// no comparison is active.
  String? _lastComparisonKey;

  /// The comparison election's precincts as points, kept for the lifetime of
  /// the comparison so that edited groups can be re-aggregated without reading
  /// and re-parsing the other database.
  List<BaselinePoint> _baselinePoints = const [];

  MapDataStore(this.electionStore, this.mapStateStore, {this.customLayerStore}) {
    effect(() {
      final folder = electionStore.selectedElectionFolder.value;
      final subItem = electionStore.selectedSubItem.value;

      if (folder == null || subItem == null || folder.isEmpty) {
        _pendingSelection = null;
        clearData();
      } else if (folder != _lastLoadedFolder || subItem != _lastLoadedSubItem) {
        _pendingSelection = (folder, subItem);
        if (!_loading) _drainPendingSelection();
      }
    });

    effect(() {
      _syncComparison(
        isComparisonMode: mapStateStore.fillMode.value.isComparison,
        compareFolder: mapStateStore.comparisonElectionFolder.value,
        stateCode: electionStore.selectedSubItem.value?.stateCode,
        office: activeElection.value?.office,
      );
    });

    final layerStore = customLayerStore;
    if (layerStore != null) {
      effect(() {
        // Subscribe to the active layer (any edit replaces it) and to the
        // loaded geometry; the rebuild itself is debounced so a burst of
        // clicks in the editor costs one outline pass, not one per click.
        layerStore.activeLayer.value;
        dataVersion.value;
        _customRebuildTimer?.cancel();
        _customRebuildTimer = Timer(
          const Duration(milliseconds: 120),
          _rebuildCustomCells,
        );
      });
    }
  }

  // ── Custom layer renderables ──

  void _rebuildCustomCells() {
    final layer = customLayerStore?.activeLayer.peek();
    final precinctIdx = cellIndex.peek()[LayerType.precinct];
    final version = dataVersion.peek();

    if (_groupCellCacheVersion != version) {
      _groupCellCache.clear();
      _groupCellCacheVersion = version;
    }

    if (layer == null || precinctIdx == null || precinctIdx.isEmpty) {
      _groupCellCache.clear();
      if (customCells.peek().isEmpty && customPrecincts.peek().isEmpty) return;
      batch(() {
        customCells.value = [];
        customCellIndex.value = {};
        customPrecincts.value = {};
        customGroupColors.value = {};
        customGroupOfPrecinct.value = {};
        customVersion.value = customVersion.peek() + 1;
      });
      return;
    }

    final cells = <RenderableCell>[];
    final index = <int, RenderableCell>{};
    final byGroup = <int, List<int>>{};
    final colors = <int, Color>{};
    final ofPrecinct = <int, int>{};
    final liveIds = <int>{};

    for (final group in layer.groups) {
      liveIds.add(group.id);
      colors[group.id] = group.color;
      byGroup[group.id] = group.precinctIds.toList();
      for (final p in group.precinctIds) {
        ofPrecinct[p] = group.id;
      }

      final cached = _groupCellCache[group.id];
      RenderableCell cell;
      if (cached != null &&
          identical(cached.precinctIds, group.precinctIds) &&
          cached.title == group.title) {
        cell = cached.cell;
      } else {
        cell = _buildGroupCell(group, precinctIdx);
        _groupCellCache[group.id] = (
          precinctIds: group.precinctIds,
          title: group.title,
          cell: cell,
        );
      }
      cells.add(cell);
      index[group.id] = cell;
    }
    _groupCellCache.removeWhere((id, _) => !liveIds.contains(id));

    batch(() {
      customCells.value = cells;
      customCellIndex.value = index;
      customPrecincts.value = byGroup;
      customGroupColors.value = colors;
      customGroupOfPrecinct.value = ofPrecinct;
      customVersion.value = customVersion.peek() + 1;
    });

    // The groups just moved, so their share of the comparison election has to
    // be re-aggregated onto the new outlines.
    _refreshCustomComparison();
  }

  /// A group's fill is simply all of its precinct paths; its border is the
  /// outline those precincts form together (see [RegionOutline]).
  RenderableCell _buildGroupCell(
    GroupCell group,
    Map<int, RenderableCell> precinctIdx,
  ) {
    final fill = Path()..fillType = PathFillType.evenOdd;
    final coords = <GeoCoordData>[];
    Rect? bounds;
    var population = 0;

    for (final id in group.precinctIds) {
      final rc = precinctIdx[id];
      if (rc == null) continue;
      fill.addPath(rc.path, Offset.zero);
      bounds = bounds == null ? rc.bounds : bounds.expandToInclude(rc.bounds);
      population += rc.cell.population;
      final wkb = rc.cell.boundaryWkb;
      if (wkb != null) {
        coords.add(GeometryParser.parseWkbToCoords(wkb, projection: projection));
      }
    }

    return RenderableCell(
      cell: GeoCell(
        id: group.id,
        name: group.title,
        layerType: LayerType.custom,
        population: population,
      ),
      path: fill,
      exteriorPath: RegionOutline.outlineOf(coords),
      bounds: bounds ?? Rect.zero,
    );
  }

  /// Precincts of a cell in any built-in state layer (a precinct is its own
  /// single member), for adding a whole county/district to a group at once.
  List<int> precinctIdsOfCell(LayerType layer, int cellId) {
    switch (layer) {
      case LayerType.precinct:
        return cellIndex.value[LayerType.precinct]?.containsKey(cellId) == true
            ? [cellId]
            : const [];
      case LayerType.county:
        return countyPrecincts.value[cellId] ?? const [];
      case LayerType.congressionalDistrict:
        return cdPrecincts.value[cellId] ?? const [];
      case LayerType.custom:
        return customPrecincts.value[cellId] ?? const [];
      case LayerType.state:
        return precinctVotes.value.keys.toList();
    }
  }

  /// Which whole counties / districts a precinct set contains, and how many
  /// precincts are left over once those are taken out.
  GroupComposition compositionOf(Set<int> precinctIds) {
    if (precinctIds.isEmpty) return GroupComposition.empty;
    final covered = <int>{};

    List<GeoCell> whole(LayerType layer, Map<int, List<int>> membership) {
      final cells = cellIndex.value[layer] ?? const <int, RenderableCell>{};
      final result = <GeoCell>[];
      membership.forEach((regionId, members) {
        if (members.isEmpty || !members.every(precinctIds.contains)) return;
        final cell = cells[regionId]?.cell;
        if (cell == null) return;
        result.add(cell);
        covered.addAll(members);
      });
      result.sort((a, b) => a.name.compareTo(b.name));
      return result;
    }

    final wholeCounties = whole(LayerType.county, countyPrecincts.value);
    final wholeDistricts =
        whole(LayerType.congressionalDistrict, cdPrecincts.value);
    return GroupComposition(
      wholeCounties: wholeCounties,
      wholeDistricts: wholeDistricts,
      remainingPrecincts: precinctIds.difference(covered).length,
      totalPrecincts: precinctIds.length,
    );
  }

  /// Sums the current election's votes over an arbitrary precinct set. Used by
  /// the editor, whose group under construction is not a loaded cell yet.
  PrecinctVoteSummary? aggregateVotesForPrecincts(Iterable<int> precinctIds) =>
      _aggregate(precinctIds);

  /// (Re)loads the comparison data for the current selection.
  ///
  /// [force] re-runs it even when nothing in the selection changed: the
  /// precinct match is built against the loaded geometry, so a comparison
  /// picked while the map was still loading has to be redone afterwards.
  void _syncComparison({
    required bool isComparisonMode,
    required String? compareFolder,
    required String? stateCode,
    required String? office,
    bool force = false,
  }) {
    // The other election names the same state's file its own way (`TX.db`
    // vs `TX-2024.db`), so the file is looked up by state.
    final dbName = isComparisonMode && compareFolder != null && stateCode != null
        ? electionStore.dbNameFor(compareFolder, stateCode)
        : null;
    final needed = dbName != null && dbName.isNotEmpty;
    // The office is part of the key: a year folder holds several contests
    // and the comparison follows whichever one is on the map.
    final key = needed ? '$compareFolder/$dbName/${office ?? ''}' : null;

    if (key == null) {
      if (_lastComparisonKey == null) return;
      _lastComparisonKey = null;
      clearComparisonData();
      return;
    }
    if (key == _lastComparisonKey && !force) return;
    _lastComparisonKey = key;
    _loadComparison(compareFolder!, dbName!, key, office: office);
  }

  /// Loads the latest requested selection, then whatever was requested while
  /// that load was running — so the map always ends up on the selection the
  /// user made last, not on the one that happened to start first.
  Future<void> _drainPendingSelection() async {
    while (_pendingSelection != null) {
      final (folder, subItem) = _pendingSelection!;
      _pendingSelection = null;
      _lastLoadedFolder = folder;
      _lastLoadedSubItem = subItem;
      await _loadSelection(folder, subItem);
    }
  }

  void clearComparisonData() {
    _baselinePoints = const [];
    comparisonRegionVotes.value = {};
    comparisonPrecinctVotes.value = {};
    comparisonVersion.value = comparisonVersion.peek() + 1;
  }

  /// Group cells are drawn by the user and change as they are edited, so their
  /// share of the comparison election has to be re-aggregated each time.
  void _refreshCustomComparison() {
    if (_baselinePoints.isEmpty) return;
    comparisonRegionVotes.value = {
      ...comparisonRegionVotes.peek(),
      LayerType.custom:
          aggregateBaselineInto(customCells.peek(), _baselinePoints),
    };
    comparisonVersion.value = comparisonVersion.peek() + 1;
  }

  /// Loads the same state's database from another election and reduces it to
  /// per-region party shares.
  ///
  /// [key] identifies the selection this load was started for: switching
  /// election mid-load starts another one, and the superseded load must drop
  /// its results instead of overwriting the newer ones.
  Future<void> _loadComparison(
    String compareFolder,
    String dbName,
    String key, {
    String? office,
  }) async {
    isLoadingComparison.value = true;
    try {
      final db = await _dbHelper.getComparisonStateDb(compareFolder, dbName);
      if (_lastComparisonKey != key) return;
      if (db == null) {
        debugPrint('Comparison DB $dbName not found in $compareFolder');
        clearComparisonData();
        return;
      }

      // {candidateId: party code} for the other election. A year-folder
      // database carries its parties and candidates itself, per contest, and
      // the contest compared against is the one for the office on the map.
      // A legacy database's live in meta.json.
      final partyNameByCandidate = <String, String>{};
      int? electionId;
      if (await _repo.hasElectionsTable(db)) {
        final contests = await _repo.loadElections(db);
        final contest = _pickContest(contests, office ?? 'President');
        if (contest == null) {
          debugPrint('Comparison DB $dbName in $compareFolder holds no contests');
          clearComparisonData();
          return;
        }
        electionId = contest.id;
        final partyNameById = {
          for (final p in await _repo.loadParties(db, contest.id)) p.id: p.name,
        };
        for (final c in await _repo.loadCandidates(db, contest.id)) {
          final party = partyNameById[c.partyId];
          if (party != null) partyNameByCandidate[c.id] = party;
        }
        electionStore.rememberPartyNames(compareFolder, partyNameById.values);
      } else {
        // peek(): this runs inside the comparison effect, and subscribing it
        // to the meta map would re-trigger it on every local-database rescan.
        final meta = electionStore.localElectionMeta.peek()[compareFolder];
        final partyNameById = {
          for (final p in meta?.parties ?? const <Party>[]) p.id: p.name,
        };
        for (final c in meta?.candidates ?? const <Candidate>[]) {
          final party = partyNameById[c.partyId];
          if (party != null) partyNameByCandidate[c.id] = party;
        }
      }
      if (_lastComparisonKey != key) return;

      final precinctVoteMap =
          await _repo.loadPrecinctVoteMap(db, electionId: electionId);
      if (_lastComparisonKey != key) return;

      // The boundary blobs are by far the most expensive read here, and every
      // level is rebuilt from them.
      final baselineCells =
          _toRenderable(await _repo.loadPrecinctGeometry(db));
      if (_lastComparisonKey != key) return;

      final baselineVotes =
          votesByPrecinctId(precinctVoteMap, partyNameByCandidate);

      // Reduce the geometry to points before anything else: the paths are
      // needed only for the precinct match below, while the points outlive
      // the load so that groups can be re-aggregated as they are edited.
      _baselinePoints = [
        for (final cell in baselineCells)
          if (baselineVotes[cell.cell.id] case final votes?)
            BaselinePoint(_centreOf(cell), votes),
      ];

      comparisonRegionVotes.value = {
        LayerType.county:
            aggregateBaselineInto(counties.value, _baselinePoints),
        LayerType.congressionalDistrict:
            aggregateBaselineInto(congressionalDistricts.value, _baselinePoints),
        LayerType.custom:
            aggregateBaselineInto(customCells.value, _baselinePoints),
      };
      comparisonPrecinctVotes.value =
          _matchPrecinctsToComparison(baselineCells, baselineVotes);
      comparisonVersion.value = comparisonVersion.peek() + 1;
    } catch (e, stack) {
      debugPrint('Error loading comparison $compareFolder/$dbName: $e\n$stack');
      if (_lastComparisonKey == key) clearComparisonData();
    } finally {
      // A superseded load leaves the flag to the load that replaced it.
      if (_lastComparisonKey == key) isLoadingComparison.value = false;
    }
  }

  /// The stored centre, projected like the geometry, is preferred over the
  /// bounding box's.
  Offset _centreOf(RenderableCell rCell) =>
      rCell.cell.centerLat != null && rCell.cell.centerLon != null
          ? projection.project(rCell.cell.centerLon!, rCell.cell.centerLat!)
          : rCell.bounds.center;

  static Rect? _boundsOf(List<RenderableCell> cells) {
    Rect? bounds;
    for (final c in cells) {
      if (c.bounds.isEmpty) continue;
      bounds = bounds == null ? c.bounds : bounds.expandToInclude(c.bounds);
    }
    return bounds;
  }

  List<RenderableCell> _toRenderable(List<GeoCell> cells) {
    final result = <RenderableCell>[];
    for (final cell in cells) {
      final wkb = cell.boundaryWkb;
      if (wkb == null) continue;
      final pathData = GeometryParser.coordsToPath(
          GeometryParser.parseWkbToCoords(wkb, projection: projection));
      if (pathData.bounds.isEmpty) continue;
      result.add(RenderableCell(
        cell: cell,
        path: pathData.path,
        exteriorPath: pathData.exteriorPath,
        bounds: pathData.bounds,
      ));
    }
    return result;
  }

  /// Re-aggregates the comparison election onto the current map: every
  /// baseline precinct's votes are added to whichever [currentRegions] cell
  /// contains its centre.
  ///
  /// This is what makes a redrawn map comparable. Joining regions by name
  /// instead would silently compare different ground — Texas redrew all of its
  /// congressional districts after the 2020 census, so a fifth of the votes in
  /// its 2024 "District 13" come from a suburban county the 2020 district of
  /// that name never contained.
  ///
  /// Every baseline precinct lands in at most one region, so the totals stay
  /// additive: unlike carrying shares over, summing these never counts a
  /// precinct twice.
  @visibleForTesting
  static Map<int, RegionPartyVotes> aggregateBaselineInto(
    List<RenderableCell> currentRegions,
    List<BaselinePoint> baselinePoints,
  ) {
    final bounds = _boundsOf(currentRegions);
    if (bounds == null || baselinePoints.isEmpty) return const {};
    final index = SpatialIndex.build(currentRegions, bounds);

    final votesByRegion = <int, Map<String, int>>{};
    final totals = <int, int>{};
    for (final point in baselinePoints) {
      final hit = index.hitTest(point.centre, currentRegions);
      if (hit < 0) continue;

      final regionId = currentRegions[hit].cell.id;
      totals[regionId] = (totals[regionId] ?? 0) + point.votes.totalVotes;
      final acc = votesByRegion.putIfAbsent(regionId, () => {});
      point.votes.votesByParty.forEach((party, n) {
        acc[party] = (acc[party] ?? 0) + n;
      });
    }

    return {
      for (final entry in totals.entries)
        if (entry.value > 0)
          entry.key: RegionPartyVotes(
            totalVotes: entry.value,
            votesByParty: votesByRegion[entry.key] ?? const {},
          ),
    };
  }

  /// Gives every precinct of the *current* election the totals of the
  /// comparison election's precinct that contains its centre.
  ///
  /// The other levels aggregate baseline precincts into current regions, but
  /// precincts are matched the opposite way: current precincts are smaller and
  /// more numerous than their counterparts, so aggregating into them would
  /// leave the ones carved out of a larger old precinct with nothing. Carrying
  /// the counterpart's totals over instead keeps the *share* meaningful for
  /// every precinct, at the cost of the counts being the counterpart's.
  Map<int, RegionPartyVotes> _matchPrecinctsToComparison(
    List<RenderableCell> baselinePrecincts,
    Map<int, RegionPartyVotes> baselineVotes,
  ) {
    final current = precincts.value;
    final bounds = _boundsOf(baselinePrecincts);
    if (current.isEmpty || bounds == null) return const {};
    final index = SpatialIndex.build(baselinePrecincts, bounds);

    final matched = <int, RegionPartyVotes>{};
    var unmatched = 0;
    for (final rCell in current) {
      final hit = index.hitTest(_centreOf(rCell), baselinePrecincts);
      final votes =
          hit < 0 ? null : baselineVotes[baselinePrecincts[hit].cell.id];
      if (votes == null) {
        unmatched++;
        continue;
      }
      matched[rCell.cell.id] = votes;
    }
    if (unmatched > 0) {
      debugPrint('Comparison: $unmatched of ${current.length} precincts have '
          'no counterpart in the comparison election');
    }
    return matched;
  }

  /// Per-party totals of one precinct, keyed by precinct id.
  @visibleForTesting
  static Map<int, RegionPartyVotes> votesByPrecinctId(
    Map<int, Map<String, int>> precinctVotes,
    Map<String, String> partyNameByCandidate,
  ) {
    final result = <int, RegionPartyVotes>{};
    for (final entry in precinctVotes.entries) {
      var total = 0;
      final byParty = <String, int>{};
      for (final v in entry.value.entries) {
        total += v.value;
        final party = partyNameByCandidate[v.key];
        if (party == null) continue;
        byParty[party] = (byParty[party] ?? 0) + v.value;
      }
      if (total <= 0) continue;
      result[entry.key] =
          RegionPartyVotes(totalVotes: total, votesByParty: byParty);
    }
    return result;
  }

  /// Party totals for [cell]'s region in the comparison election, or null when
  /// that region has no counterpart there.
  ///
  /// Everything is keyed by the *current* election's own ids: counties and
  /// districts because the other election's votes were re-aggregated onto this
  /// map, precincts because they were matched to it geometrically.
  RegionPartyVotes? comparisonVotesFor(LayerType layer, GeoCell cell) {
    switch (layer) {
      case LayerType.precinct:
        return comparisonPrecinctVotes.value[cell.id];
      case LayerType.custom:
      case LayerType.state:
      case LayerType.county:
      case LayerType.congressionalDistrict:
        return comparisonRegionVotes.value[layer]?[cell.id];
    }
  }

  /// Vote share of [partyName] in the comparison election for [cell]'s region,
  /// or null when that region has no counterpart there.
  double? comparisonShareFor(LayerType layer, GeoCell cell, String partyName) =>
      comparisonVotesFor(layer, cell)?.shareOf(partyName);

  /// The whole state's votes for the current contest, or null before any
  /// state is loaded.
  PrecinctVoteSummary? stateVoteSummary() =>
      aggregateVotesForRegion(LayerType.state, 0);

  /// Seats of the loaded contest, meaningful only when it is a US House race.
  HouseSeatSummary houseSeatsIn(PrecinctVoteSummary summary) =>
      HouseSeatSummary.compute(
        candidates: candidates.value,
        candidatePartyMap: candidatePartyMap.value,
        parties: parties.value,
        candidateVotes: summary.candidateVotes,
      );

  /// Party totals within an already-aggregated region of the current election.
  Map<String, int> partyVotesIn(PrecinctVoteSummary summary) {
    final byParty = <String, int>{};
    candidateIdsByPartyName.value.forEach((partyName, candidateIds) {
      var votes = 0;
      for (final id in candidateIds) {
        votes += summary.candidateVotes[id] ?? 0;
      }
      if (votes > 0) byParty[partyName] = votes;
    });
    return byParty;
  }

  /// Vote share of [partyName] within an already-aggregated region of the
  /// current election.
  double partyShareIn(PrecinctVoteSummary summary, String partyName) {
    if (summary.totalVotes <= 0) return 0.0;
    final ids = candidateIdsByPartyName.value[partyName];
    if (ids == null) return 0.0;
    var votes = 0;
    for (final id in ids) {
      votes += summary.candidateVotes[id] ?? 0;
    }
    return votes / summary.totalVotes;
  }

  void clearData() {
    _lastLoadedFolder = null;
    _lastLoadedSubItem = null;
    states.value = [];
    counties.value = [];
    congressionalDistricts.value = [];
    precincts.value = [];
    cellIndex.value = {};
    overallBounds.value = null;
    projection = MapProjection.identity;
    precinctVotes.value = {};
    candidatePartyMap.value = {};
    candidateIdsByPartyName.value = {};
    candidates.value = [];
    parties.value = {};
    availableElections.value = [];
    activeElection.value = null;
    _newSchema = false;
    _loadedDbName = null;
    countyPrecincts.value = {};
    cdPrecincts.value = {};
    _lastComparisonKey = null;
    clearComparisonData();
    // peek(): clearData() runs inside the selection effect, and a plain `++`
    // would subscribe that effect to dataVersion and then re-trigger it.
    dataVersion.value = dataVersion.peek() + 1;
    _dbHelper.closeCurrentElection();
  }

  /// Candidates and parties come from the election manifest (meta.json), not
  /// from the databases.
  void _loadElectionMetadata(String folder) {
    final meta = electionStore.localElectionMeta.value[folder];
    candidates.value = meta?.candidates ?? [];
    parties.value = {for (final p in meta?.parties ?? const <Party>[]) p.id: p};
    candidatePartyMap.value = {
      for (final c in candidates.value)
        if (c.partyId != null) c.id: c.partyId!,
    };

    final byPartyName = <String, List<String>>{};
    for (final c in candidates.value) {
      final partyName = parties.value[c.partyId]?.name;
      if (partyName == null) continue;
      byPartyName.putIfAbsent(partyName, () => []).add(c.id);
    }
    candidateIdsByPartyName.value = byPartyName;
  }

  /// The contest for [office] among [contests], or the first one when the
  /// state did not hold that contest. Special elections are never picked by
  /// default — a state with both lists the regular one first.
  static ElectionContest? _pickContest(
    List<ElectionContest> contests,
    String office,
  ) {
    if (contests.isEmpty) return null;
    return contests.where((c) => c.office == office && !c.special).firstOrNull ??
        contests.where((c) => c.office == office).firstOrNull ??
        contests.first;
  }

  /// Reads one contest's parties and candidates out of a year-folder database
  /// and publishes them as the current election's.
  Future<void> _loadContestMetadata(Database db, ElectionContest contest) async {
    final partyList = await _repo.loadParties(db, contest.id);
    final candidateList =
        await _repo.loadCandidates(db, contest.id, office: contest.office);
    candidates.value = [
      for (final c in candidateList)
        Candidate(
          id: c.id,
          name: c.displayName,
          partyId: c.partyId,
          office: c.office,
          district: c.district,
        ),
    ];
    parties.value = {for (final p in partyList) p.id: p};
    candidatePartyMap.value = {
      for (final c in candidates.value)
        if (c.partyId != null) c.id: c.partyId!,
    };
    final byPartyName = <String, List<String>>{};
    for (final c in candidates.value) {
      final partyName = parties.value[c.partyId]?.name;
      if (partyName == null) continue;
      byPartyName.putIfAbsent(partyName, () => []).add(c.id);
    }
    candidateIdsByPartyName.value = byPartyName;
  }

  /// {precinctId: summary} from the vote rows of one contest (or of the whole
  /// legacy database when [electionId] is null).
  Future<Map<int, PrecinctVoteSummary>> _loadPrecinctSummaries(
    String dbName,
    Map<int, GeoCell> precinctsById, {
    int? electionId,
  }) async {
    final voteMap =
        await _repo.getPrecinctVoteMapForState(dbName, electionId: electionId);
    final summaries = <int, PrecinctVoteSummary>{};
    for (final entry in voteMap.entries) {
      final precinctId = entry.key;
      final cvotes = entry.value;
      int total = 0;
      String? winnerId;
      int winnerVotes = 0;
      for (final cv in cvotes.entries) {
        total += cv.value;
        if (cv.value > winnerVotes) {
          winnerVotes = cv.value;
          winnerId = cv.key;
        }
      }
      summaries[precinctId] = PrecinctVoteSummary(
        totalVotes: total,
        winnerCandidateId: winnerId,
        winnerVotes: winnerVotes,
        candidateVotes: cvotes,
        population: precinctsById[precinctId]?.population ?? 0,
      );
    }
    return summaries;
  }

  /// Switches the loaded state to another of its contests (President → US
  /// Senate, …). Geometry stays; candidates, parties and votes are replaced.
  ///
  /// Also records [office] as the preferred one, so the next state opens on
  /// it. On a legacy database only the preference changes.
  Future<void> setOffice(String office) async {
    final contest = _pickContest(availableElections.value, office);
    if (contest == null) {
      electionStore.setSelectedOffice(office);
      return;
    }
    await setContest(contest);
  }

  /// Switches to one specific contest of the loaded state — how a special
  /// election, which [setOffice] never picks by itself, is chosen.
  Future<void> setContest(ElectionContest contest) async {
    electionStore.setSelectedOffice(contest.office);
    final dbName = _loadedDbName;
    if (!_newSchema || dbName == null || _loading) return;
    if (contest == activeElection.value) return;
    await _switchContest(dbName, contest);
  }

  Future<void> _switchContest(String dbName, ElectionContest contest) async {
    _loading = true;
    isLoadingData.value = true;
    try {
      final db = await _dbHelper.getStateDb(dbName);
      await _loadContestMetadata(db, contest);
      final precinctsById = {
        for (final rc in precincts.value) rc.cell.id: rc.cell,
      };
      precinctVotes.value =
          await _loadPrecinctSummaries(dbName, precinctsById, electionId: contest.id);
      activeElection.value = contest;
      // Candidate and party ids are minted per contest, so a pick made for the
      // previous one means nothing now.
      mapStateStore.selectedCandidateId.value = null;
      mapStateStore.comparisonPartyAId.value = null;
      mapStateStore.comparisonPartyBId.value = null;
    } catch (e, stack) {
      debugPrint('Error switching $dbName to ${contest.label}: $e\n$stack');
    } finally {
      _loading = false;
      dataVersion.value = dataVersion.peek() + 1;
      isLoadingData.value = false;
      _syncComparison(
        isComparisonMode: mapStateStore.fillMode.peek().isComparison,
        compareFolder: mapStateStore.comparisonElectionFolder.peek(),
        stateCode: ElectionSubItem.stateCodeOf(dbName),
        office: contest.office,
        force: true,
      );
      if (_pendingSelection != null) _drainPendingSelection();
    }
  }

  GeoCoordData? _parseCellCoords(GeoCell cell) {
    if (cell.boundaryWkb != null) {
      return GeometryParser.parseWkbToCoords(cell.boundaryWkb!,
          projection: projection);
    }
    return null;
  }

  Future<void> _loadSelection(String folder, ElectionSubItem subItem) async {
    _loading = true;
    isLoadingData.value = true;
    mapStateStore.resetSelection();

    try {
      await _dbHelper.openElection(folder);
      _loadElectionMetadata(folder);

      if (subItem.isNational) {
        // --- NATIONAL VIEW ---
        final rawStates = await _repo.getStates();

        final summaries = <int, PrecinctVoteSummary>{};
        for (final cell in rawStates) {
          final summaryJson = cell.voteSummaryJson;
          if (summaryJson != null && summaryJson.isNotEmpty) {
            try {
              final List<dynamic> list = json.decode(summaryJson);
              final cvotes = <String, int>{};
              int total = 0;
              String? winnerId;
              int winnerVotes = 0;

              for (final item in list) {
                if (item is Map) {
                  final cid = (item['candidate_id'] ?? item['candiate_id']).toString();
                  final v = (item['votes'] as num).toInt();
                  cvotes[cid] = v;
                  total += v;
                  if (v > winnerVotes) {
                    winnerVotes = v;
                    winnerId = cid;
                  }
                }
              }
              summaries[cell.id] = PrecinctVoteSummary(
                totalVotes: total,
                winnerCandidateId: winnerId,
                winnerVotes: winnerVotes,
                candidateVotes: cvotes,
                population: cell.population,
              );
            } catch (e) {
              debugPrint('Error parsing state vote_summary for ${cell.name}: $e');
            }
          }
        }
        precinctVotes.value = summaries;

        final renderableStates = <RenderableCell>[];
        double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;

        projection = _projectionFor(rawStates);
        for (final cell in rawStates) {
          final coordData = _parseCellCoords(cell);
          if (coordData != null) {
            final pathData = GeometryParser.coordsToPath(coordData);

            // A cell whose geometry produced no rings has Rect.zero bounds;
            // folding that in would stretch the extent all the way to (0, 0).
            if (!pathData.bounds.isEmpty) {
              if (pathData.bounds.left < minX) minX = pathData.bounds.left;
              if (pathData.bounds.top < minY) minY = pathData.bounds.top;
              if (pathData.bounds.right > maxX) maxX = pathData.bounds.right;
              if (pathData.bounds.bottom > maxY) maxY = pathData.bounds.bottom;
            }

            renderableStates.add(RenderableCell(
              cell: cell,
              path: pathData.path,
              exteriorPath: pathData.exteriorPath,
              bounds: pathData.bounds,
            ));
          }
        }

        states.value = renderableStates;
        counties.value = [];
        congressionalDistricts.value = [];
        precincts.value = [];
        cellIndex.value = {
          LayerType.state: {for (final c in renderableStates) c.cell.id: c},
        };

        // Clearing on empty matters: keeping the previous selection's extent
        // leaves the canvas looking loaded while nothing is drawn on it.
        overallBounds.value = minX != double.infinity
            ? Rect.fromLTRB(minX, minY, maxX, maxY)
            : null;

        // National view: visible layers fixed to [state]
        mapStateStore.setVisibleLayers([LayerType.state]);
      } else {
        // --- STATE VIEW (e.g. Texas / TX.db) ---
        final dbName = subItem.dbName;
        if (dbName != null && dbName.isNotEmpty) {
          final records = await _repo.getStateRegions(dbName);
          final countyIds = records.where((r) => r.regionType == 'county').map((r) => r.regionId).toList();
          final cdIds = records.where((r) => r.regionType == 'congressional_district').map((r) => r.regionId).toList();

          final rawCounties = await _repo.getCountiesForState(dbName, countyIds);
          final rawCds = await _repo.getCongressionalDistrictsForState(dbName, cdIds);
          final rawPrecincts = await _repo.getPrecinctsForState(dbName);
          final precMap = {for (final p in rawPrecincts) p.id: p};

          // A year-folder database holds several contests with their own
          // candidates and parties; a legacy one holds the presidential
          // votes and takes candidates and parties from meta.json (already
          // loaded above).
          final stateDb = await _dbHelper.getStateDb(dbName);
          _loadedDbName = dbName;
          _newSchema = await _repo.hasElectionsTable(stateDb);
          ElectionContest? contest;
          if (_newSchema) {
            final contests = await _repo.loadElections(stateDb);
            contest = _pickContest(contests, electionStore.selectedOffice.peek());
            availableElections.value = contests;
            if (contest != null) await _loadContestMetadata(stateDb, contest);
            electionStore.rememberPartyNames(folder, parties.value.values.map((p) => p.name));
          } else {
            availableElections.value = const [ElectionContest.legacyPresident];
            contest = ElectionContest.legacyPresident;
          }
          activeElection.value = contest;

          final countyPrec = await _repo.getCountyPrecinctMapForState(dbName);
          final cdPrec = await _repo.getCdPrecinctMapForState(dbName);
          precinctVotes.value = await _loadPrecinctSummaries(
            dbName,
            precMap,
            electionId: _newSchema ? contest?.id : null,
          );
          countyPrecincts.value = countyPrec;
          cdPrecincts.value = cdPrec;

          final allStateCells = <GeoCell>[
            ...rawCounties,
            ...rawCds,
            ...rawPrecincts,
          ];

          final renderableCells = <RenderableCell>[];
          double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;

          projection = _projectionFor(allStateCells);
          for (final cell in allStateCells) {
            final coordData = _parseCellCoords(cell);
            if (coordData != null) {
              final pathData = GeometryParser.coordsToPath(coordData);
              if (!pathData.bounds.isEmpty) {
                if (pathData.bounds.left < minX) minX = pathData.bounds.left;
                if (pathData.bounds.top < minY) minY = pathData.bounds.top;
                if (pathData.bounds.right > maxX) maxX = pathData.bounds.right;
                if (pathData.bounds.bottom > maxY) maxY = pathData.bounds.bottom;
              }

              renderableCells.add(RenderableCell(
                cell: cell,
                path: pathData.path,
                exteriorPath: pathData.exteriorPath,
                bounds: pathData.bounds,
              ));
            }
          }

          states.value = [];
          counties.value = renderableCells.where((r) => r.cell.layerType == LayerType.county).toList();
          congressionalDistricts.value = renderableCells.where((r) => r.cell.layerType == LayerType.congressionalDistrict).toList();
          precincts.value = renderableCells.where((r) => r.cell.layerType == LayerType.precinct).toList();

          final index = <LayerType, Map<int, RenderableCell>>{};
          for (final c in renderableCells) {
            (index[c.cell.layerType] ??= {})[c.cell.id] = c;
          }
          cellIndex.value = index;

          overallBounds.value = minX != double.infinity
              ? Rect.fromLTRB(minX, minY, maxX, maxY)
              : null;

          // State view: visible layers MUST NOT include state or precinct by
          // default. County is both the finest visible layer and the one the
          // interactive/filled selections derive from.
          mapStateStore.setVisibleLayers(
              [LayerType.county, LayerType.congressionalDistrict]);
        }
      }
    } catch (e, stack) {
      debugPrint("Error loading selection ($folder - ${subItem.name}): $e\n$stack");
    } finally {
      _loading = false;
      dataVersion.value = dataVersion.peek() + 1;
      isLoadingData.value = false;

      // A comparison chosen while this load was running matched against
      // precincts that were not there yet — redo it now that they are.
      _syncComparison(
        isComparisonMode: mapStateStore.fillMode.peek().isComparison,
        compareFolder: mapStateStore.comparisonElectionFolder.peek(),
        stateCode: subItem.stateCode,
        office: activeElection.peek()?.office,
        force: true,
      );
    }
  }

  /// Aggregate votes for a non-precinct cell by summing its child precincts.
  PrecinctVoteSummary? aggregateVotesForRegion(LayerType layerType, int regionId) {
    final votes = precinctVotes.value;
    List<int>? precinctIds;

    switch (layerType) {
      case LayerType.county:
        precinctIds = countyPrecincts.value[regionId];
      case LayerType.congressionalDistrict:
        precinctIds = cdPrecincts.value[regionId];
      case LayerType.custom:
        precinctIds = customPrecincts.value[regionId];
      case LayerType.state:
        precinctIds = votes.keys.toList();
      case LayerType.precinct:
        final pv = votes[regionId];
        final focus = focusPrecincts.value;
        if (pv == null || focus == null || focus.contains(regionId)) return pv;
        return _noVotes(pv.population);
    }

    if (precinctIds == null || precinctIds.isEmpty) return null;
    return _aggregate(precinctIds);
  }

  /// What a precinct outside the "Only See" district reports: its people are
  /// still there, its ballots are not.
  static PrecinctVoteSummary _noVotes(int population) => PrecinctVoteSummary(
        totalVotes: 0,
        winnerCandidateId: null,
        winnerVotes: 0,
        candidateVotes: const {},
        population: population,
      );

  PrecinctVoteSummary? _aggregate(Iterable<int> precinctIds) {
    final votes = precinctVotes.value;
    final focus = focusPrecincts.value;
    final aggregated = <String, int>{};
    int total = 0;
    int pop = 0;
    for (final pid in precinctIds) {
      final pv = votes[pid];
      if (pv == null) continue;
      pop += pv.population;
      if (focus != null && !focus.contains(pid)) continue;
      total += pv.totalVotes;
      for (final entry in pv.candidateVotes.entries) {
        aggregated[entry.key] = (aggregated[entry.key] ?? 0) + entry.value;
      }
    }

    // Without a focus, no votes means no data; with one, it means the region
    // lies outside the district being looked at, which is worth reporting.
    if (total == 0) return focus == null ? null : _noVotes(pop);

    String? winnerId;
    int winnerVotes = 0;
    for (final entry in aggregated.entries) {
      if (entry.value > winnerVotes) {
        winnerVotes = entry.value;
        winnerId = entry.key;
      }
    }

    return PrecinctVoteSummary(
      totalVotes: total,
      winnerCandidateId: winnerId,
      winnerVotes: winnerVotes,
      candidateVotes: aggregated,
      population: pop,
    );
  }
}
