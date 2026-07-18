import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:flutter/painting.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/repositories/election_repository.dart';
import 'package:gerrymanderx/core/utils/geojson_parser.dart';
import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/providers/election_store.dart';

class RenderableCell {
  final GeoCell cell;
  final Path path;
  final Rect bounds;

  RenderableCell({required this.cell, required this.path, required this.bounds});
}

/// Aggregated vote totals for a precinct.
class PrecinctVoteSummary {
  final int totalVotes;
  final int winnerCandidateId;
  final int winnerVotes;
  final Map<int, int> candidateVotes; // candidateId -> votes

  PrecinctVoteSummary({
    required this.totalVotes,
    required this.winnerCandidateId,
    required this.winnerVotes,
    required this.candidateVotes,
  });
}

class MapDataStore {
  final ElectionStore electionStore;
  final ElectionRepository _repo = ElectionRepository();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  final states = ListSignal<RenderableCell>([]);
  final counties = ListSignal<RenderableCell>([]);
  final congressionalDistricts = ListSignal<RenderableCell>([]);
  final precincts = ListSignal<RenderableCell>([]);

  /// O(1) cell lookup by ID per layer type.
  final cellIndex = Signal<Map<LayerType, Map<int, RenderableCell>>>({});

  final isLoadingData = Signal<bool>(false);
  final overallBounds = Signal<Rect?>(null);

  /// {precinctId: PrecinctVoteSummary}
  final precinctVotes = Signal<Map<int, PrecinctVoteSummary>>({});

  /// {candidateId: partyId}
  final candidatePartyMap = Signal<Map<int, int>>({});

  /// All candidates for this election
  final candidates = ListSignal<Candidate>([]);

  /// Region → precinct mappings for aggregating non-precinct cells
  /// {countyId: [precinctId, ...]}
  final countyPrecincts = Signal<Map<int, List<int>>>({});
  /// {cdId: [precinctId, ...]}
  final cdPrecincts = Signal<Map<int, List<int>>>({});

  String? _lastLoadedDb;
  bool _loading = false;

  MapDataStore(this.electionStore) {
    // Subscribe to database changes. We use subscribe instead of effect
    // because _loadAll is async and effect() can't handle Futures.
    electionStore.selectedDatabase.subscribe((db) {
      if (db != null && db != _lastLoadedDb && !_loading) {
        _lastLoadedDb = db;
        _loadAll(db);
      }
    });
  }

  Future<void> _loadAll(String dbName) async {
    _loading = true;
    isLoadingData.value = true;
    try {
      // 1. Open the chosen database.
      await _dbHelper.openNamedDatabase(dbName);

      // 2. Load geometry from DB (main thread - sqflite requires it).
      final rawStates = await _repo.getStates();
      final rawCounties = await _repo.getCounties();
      final rawCds = await _repo.getCongressionalDistricts();
      final rawPrecincts = await _repo.getPrecincts();

      // 3. Parse GeoJSON in background isolate.
      // Collect all boundary strings for batch processing.
      final allCells = <GeoCell>[
        ...rawStates.where((c) => c.boundaryJson != null),
        ...rawCounties.where((c) => c.boundaryJson != null),
        ...rawCds.where((c) => c.boundaryJson != null),
        ...rawPrecincts.where((c) => c.boundaryJson != null),
      ];
      final boundaries = allCells.map((c) => c.boundaryJson!).toList();

      // Heavy JSON parsing runs on a separate isolate.
      final coordDataList = await Isolate.run(() {
        return boundaries.map((b) => GeoJsonParser.parseGeoJsonToCoords(b)).toList();
      });

      // 4. Build Paths on main thread (fast — just moveTo/lineTo).
      double minX = double.infinity;
      double minY = double.infinity;
      double maxX = -double.infinity;
      double maxY = -double.infinity;

      final renderableCells = <RenderableCell>[];
      for (int i = 0; i < allCells.length; i++) {
        final data = coordDataList[i];
        final pathData = GeoJsonParser.coordsToPath(data);

        if (pathData.bounds.left < minX) minX = pathData.bounds.left;
        if (pathData.bounds.top < minY) minY = pathData.bounds.top;
        if (pathData.bounds.right > maxX) maxX = pathData.bounds.right;
        if (pathData.bounds.bottom > maxY) maxY = pathData.bounds.bottom;

        renderableCells.add(RenderableCell(
          cell: allCells[i],
          path: pathData.path,
          bounds: pathData.bounds,
        ));
      }

      // 5. Distribute back to layer signals.
      states.value = renderableCells.where((r) => r.cell.layerType == LayerType.state).toList();
      counties.value = renderableCells.where((r) => r.cell.layerType == LayerType.county).toList();
      congressionalDistricts.value = renderableCells.where((r) => r.cell.layerType == LayerType.congressionalDistrict).toList();
      precincts.value = renderableCells.where((r) => r.cell.layerType == LayerType.precinct).toList();

      // Build O(1) cell lookup index.
      // Build O(1) cell lookup index per layer type.
      final layerIndices = <LayerType, Map<int, RenderableCell>>{
        LayerType.state: { for (final c in states.value) c.cell.id: c },
        LayerType.county: { for (final c in counties.value) c.cell.id: c },
        LayerType.congressionalDistrict: { for (final c in congressionalDistricts.value) c.cell.id: c },
        LayerType.precinct: { for (final c in precincts.value) c.cell.id: c },
      };
      cellIndex.value = layerIndices;

      if (minX != double.infinity) {
        overallBounds.value = Rect.fromLTRB(minX, minY, maxX, maxY);
      }

      // 3. Load vote data.
      final voteMap = await _repo.getPrecinctVoteMap();
      final partyMap = await _repo.getCandidatePartyMap();
      final allCandidates = await _repo.getCandidates();

      final summaries = <int, PrecinctVoteSummary>{};
      for (final entry in voteMap.entries) {
        final precinctId = entry.key;
        final cvotes = entry.value; // {candidateId: votes}
        int total = 0;
        int winnerId = 0;
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
        );
      }

      precinctVotes.value = summaries;
      candidatePartyMap.value = partyMap;
      candidates.value = allCandidates;

      // 4. Load region → precinct mappings.
      countyPrecincts.value = await _repo.getCountyPrecinctMap();
      cdPrecincts.value = await _repo.getCdPrecinctMap();
    } finally {
      _loading = false;
      isLoadingData.value = false;
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
      case LayerType.state:
        // State = all precincts
        precinctIds = votes.keys.toList();
      case LayerType.precinct:
        return votes[regionId];
    }

    if (precinctIds == null || precinctIds.isEmpty) return null;

    final aggregated = <int, int>{}; // candidateId → total votes
    int total = 0;
    for (final pid in precinctIds) {
      final pv = votes[pid];
      if (pv == null) continue;
      total += pv.totalVotes;
      for (final entry in pv.candidateVotes.entries) {
        aggregated[entry.key] = (aggregated[entry.key] ?? 0) + entry.value;
      }
    }

    if (total == 0) return null;

    int winnerId = 0;
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
    );
  }
}
