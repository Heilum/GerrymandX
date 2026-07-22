import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:flutter/painting.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/repositories/election_repository.dart';
import 'package:gerrymanderx/core/utils/geojson_parser.dart';
import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

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
  final int population;

  PrecinctVoteSummary({
    required this.totalVotes,
    required this.winnerCandidateId,
    required this.winnerVotes,
    required this.candidateVotes,
    this.population = 0,
  });
}

class MapDataStore {
  final ElectionStore electionStore;
  final MapStateStore mapStateStore;
  final ElectionRepository _repo = ElectionRepository();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  // Layer cell data
  final states = ListSignal<RenderableCell>([]);
  final counties = ListSignal<RenderableCell>([]);
  final congressionalDistricts = ListSignal<RenderableCell>([]);
  final precincts = ListSignal<RenderableCell>([]);

  /// O(1) cell lookup by ID per layer type.
  final cellIndex = Signal<Map<int, RenderableCell>>({});

  /// Combined bounding box of all loaded geometries.
  final overallBounds = Signal<Rect?>(null);

  /// Signal to track data loading state
  final isLoadingData = Signal<bool>(false);

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

  String? _lastLoadedFolder;
  ElectionSubItem? _lastLoadedSubItem;
  bool _loading = false;

  MapDataStore(this.electionStore, this.mapStateStore) {
    effect(() {
      final folder = electionStore.selectedElectionFolder.value;
      final subItem = electionStore.selectedSubItem.value;

      if (folder == null || subItem == null || folder.isEmpty) {
        clearData();
      } else if ((folder != _lastLoadedFolder || subItem != _lastLoadedSubItem) && !_loading) {
        _lastLoadedFolder = folder;
        _lastLoadedSubItem = subItem;
        _loadSelection(folder, subItem);
      }
    });
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
    precinctVotes.value = {};
    candidatePartyMap.value = {};
    candidates.value = [];
    countyPrecincts.value = {};
    cdPrecincts.value = {};
    _dbHelper.closeCurrentElection();
  }

  GeoCoordData? _parseCellCoords(GeoCell cell) {
    if (cell.boundaryWkb != null) {
      return GeometryParser.parseWkbToCoords(cell.boundaryWkb!);
    }
    return null;
  }

  Future<void> _loadSelection(String folder, ElectionSubItem subItem) async {
    _loading = true;
    isLoadingData.value = true;
    mapStateStore.resetSelection();

    try {
      await _dbHelper.openElection(folder);

      if (subItem.isNational) {
        // --- NATIONAL VIEW ---
        final rawStates = await _repo.getStates();

        final candList = await _repo.getCandidates();
        final partyMap = await _repo.getCandidatePartyMap();
        candidates.value = candList;
        candidatePartyMap.value = partyMap;

        final summaries = <int, PrecinctVoteSummary>{};
        for (final cell in rawStates) {
          final summaryJson = cell.voteSummaryJson;
          if (summaryJson != null && summaryJson.isNotEmpty) {
            try {
              final List<dynamic> list = json.decode(summaryJson);
              final cvotes = <int, int>{};
              int total = 0;
              int winnerId = 0;
              int winnerVotes = 0;

              for (final item in list) {
                if (item is Map) {
                  final cid = ((item['candidate_id'] ?? item['candiate_id']) as num).toInt();
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

        for (final cell in rawStates) {
          final coordData = _parseCellCoords(cell);
          if (coordData != null) {
            final pathData = GeometryParser.coordsToPath(coordData);

            if (pathData.bounds.left < minX) minX = pathData.bounds.left;
            if (pathData.bounds.top < minY) minY = pathData.bounds.top;
            if (pathData.bounds.right > maxX) maxX = pathData.bounds.right;
            if (pathData.bounds.bottom > maxY) maxY = pathData.bounds.bottom;

            renderableStates.add(RenderableCell(
              cell: cell,
              path: pathData.path,
              bounds: pathData.bounds,
            ));
          }
        }

        states.value = renderableStates;
        counties.value = [];
        congressionalDistricts.value = [];
        precincts.value = [];
        cellIndex.value = {for (final c in renderableStates) c.cell.id: c};

        if (minX != double.infinity) {
          overallBounds.value = Rect.fromLTRB(minX, minY, maxX, maxY);
        }

        // National view: visible layers fixed to [state]
        mapStateStore.visibleLayers.value = [LayerType.state];
        mapStateStore.interactiveLayer.value = LayerType.state;
      } else {
        // --- STATE VIEW (e.g. Texas / TX.db) ---
        final dbName = subItem.dbName;
        if (dbName != null && dbName.isNotEmpty) {
          final stateRegionsMap = await _repo.getAllStateRegions();
          final stateId = subItem.stateId;
          final records = stateId != null ? (stateRegionsMap[stateId] ?? []) : [];
          final countyIds = records.where((r) => r.regionType == 'county').map((r) => r.regionId).toList().cast<int>();
          final cdIds = records.where((r) => r.regionType == 'congressional_district').map((r) => r.regionId).toList().cast<int>();

          final rawCounties = await _repo.getCountiesForState(dbName, countyIds);
          final rawCds = await _repo.getCongressionalDistrictsForState(dbName, cdIds);
          final rawPrecincts = await _repo.getPrecinctsForState(dbName);

          final voteMap = await _repo.getPrecinctVoteMapForState(dbName);
          final partyMap = await _repo.getCandidatePartyMapForState(dbName);
          final candList = await _repo.getCandidatesForState(dbName);
          final countyPrec = await _repo.getCountyPrecinctMapForState(dbName);
          final cdPrec = await _repo.getCdPrecinctMapForState(dbName);

          // Build PrecinctVoteSummary map
          final summaries = <int, PrecinctVoteSummary>{};
          final precMap = {for (final p in rawPrecincts) p.id: p};
          for (final entry in voteMap.entries) {
            final precinctId = entry.key;
            final cvotes = entry.value;
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
            final pop = precMap[precinctId]?.population ?? 0;
            summaries[precinctId] = PrecinctVoteSummary(
              totalVotes: total,
              winnerCandidateId: winnerId,
              winnerVotes: winnerVotes,
              candidateVotes: cvotes,
              population: pop,
            );
          }

          precinctVotes.value = summaries;
          candidatePartyMap.value = partyMap;
          candidates.value = candList;
          countyPrecincts.value = countyPrec;
          cdPrecincts.value = cdPrec;

          final allStateCells = <GeoCell>[
            ...rawCounties,
            ...rawCds,
            ...rawPrecincts,
          ];

          final renderableCells = <RenderableCell>[];
          double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;

          for (final cell in allStateCells) {
            final coordData = _parseCellCoords(cell);
            if (coordData != null) {
              final pathData = GeometryParser.coordsToPath(coordData);
              if (pathData.bounds.left < minX) minX = pathData.bounds.left;
              if (pathData.bounds.top < minY) minY = pathData.bounds.top;
              if (pathData.bounds.right > maxX) maxX = pathData.bounds.right;
              if (pathData.bounds.bottom > maxY) maxY = pathData.bounds.bottom;

              renderableCells.add(RenderableCell(
                cell: cell,
                path: pathData.path,
                bounds: pathData.bounds,
              ));
            }
          }

          states.value = [];
          counties.value = renderableCells.where((r) => r.cell.layerType == LayerType.county).toList();
          congressionalDistricts.value = renderableCells.where((r) => r.cell.layerType == LayerType.congressionalDistrict).toList();
          precincts.value = renderableCells.where((r) => r.cell.layerType == LayerType.precinct).toList();

          final index = <int, RenderableCell>{};
          for (final c in renderableCells) index[c.cell.id] = c;
          cellIndex.value = index;

          if (minX != double.infinity) {
            overallBounds.value = Rect.fromLTRB(minX, minY, maxX, maxY);
          }

          // State view: visible layers MUST NOT include state chip
          final currentLayers = List<LayerType>.from(mapStateStore.visibleLayers.value)..remove(LayerType.state);
          if (currentLayers.isEmpty) {
            currentLayers.addAll([LayerType.county, LayerType.congressionalDistrict, LayerType.precinct]);
          }
          mapStateStore.visibleLayers.value = currentLayers;
          // Ensure interactiveLayer is one of the visible layers
          if (!currentLayers.contains(mapStateStore.interactiveLayer.value)) {
            mapStateStore.interactiveLayer.value = currentLayers.first;
          }
        }
      }
    } catch (e, stack) {
      debugPrint("Error loading selection ($folder - ${subItem.name}): $e\n$stack");
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
        precinctIds = votes.keys.toList();
      case LayerType.precinct:
        return votes[regionId];
    }

    if (precinctIds == null || precinctIds.isEmpty) return null;

    final aggregated = <int, int>{};
    int total = 0;
    int pop = 0;
    for (final pid in precinctIds) {
      final pv = votes[pid];
      if (pv == null) continue;
      total += pv.totalVotes;
      pop += pv.population;
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
      population: pop,
    );
  }
}
