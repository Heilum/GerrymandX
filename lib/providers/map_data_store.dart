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

  MapDataStore(this.electionStore) {
    // Single reactive effect: when selectedDatabase changes, load everything.
    effect(() {
      final db = electionStore.selectedDatabase.value;
      if (db != null) {
        _loadAll(db);
      }
    });
  }

  Future<void> _loadAll(String dbName) async {
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
    } finally {
      isLoadingData.value = false;
    }
  }

  int? hitTest(Offset localPosition, Size canvasSize, LayerType layerType) {
    if (overallBounds.value == null) return null;
    final bounds = overallBounds.value!;

    final scaleX = canvasSize.width / bounds.width;
    final scaleY = canvasSize.height / bounds.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;

    final mapWidth = bounds.width * scale;
    final mapHeight = bounds.height * scale;
    final offsetX = (canvasSize.width - mapWidth) / 2 - bounds.left * scale;
    final offsetY = (canvasSize.height - mapHeight) / 2 - bounds.top * scale;

    final mapX = (localPosition.dx - offsetX) / scale;
    final mapY = (localPosition.dy - offsetY) / scale;
    final mapPoint = Offset(mapX, mapY);

    List<RenderableCell> targetList;
    switch (layerType) {
      case LayerType.state:
        targetList = states.value;
      case LayerType.county:
        targetList = counties.value;
      case LayerType.congressionalDistrict:
        targetList = congressionalDistricts.value;
      case LayerType.precinct:
        targetList = precincts.value;
    }

    for (final rCell in targetList) {
      if (rCell.bounds.contains(mapPoint)) {
        if (rCell.path.contains(mapPoint)) {
          return rCell.cell.id;
        }
      }
    }
    return null;
  }
}
