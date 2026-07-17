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

      // 2. Load geometry.
      final rawStates = await _repo.getStates();
      final rawCounties = await _repo.getCounties();
      final rawCds = await _repo.getCongressionalDistricts();
      final rawPrecincts = await _repo.getPrecincts();

      double minX = double.infinity;
      double minY = double.infinity;
      double maxX = -double.infinity;
      double maxY = -double.infinity;

      List<RenderableCell> processCells(List<GeoCell> cells) {
        return cells.where((c) => c.boundaryJson != null).map((c) {
          final parsed = GeoJsonParser.parseGeoJson(c.boundaryJson!);

          if (parsed.bounds.left < minX) minX = parsed.bounds.left;
          if (parsed.bounds.top < minY) minY = parsed.bounds.top;
          if (parsed.bounds.right > maxX) maxX = parsed.bounds.right;
          if (parsed.bounds.bottom > maxY) maxY = parsed.bounds.bottom;

          return RenderableCell(cell: c, path: parsed.path, bounds: parsed.bounds);
        }).toList();
      }

      states.value = processCells(rawStates);
      counties.value = processCells(rawCounties);
      congressionalDistricts.value = processCells(rawCds);
      precincts.value = processCells(rawPrecincts);

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
