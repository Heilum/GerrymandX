import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

PrecinctVoteSummary _votes(int dem, int rep) =>
    PrecinctVoteSummary(
      totalVotes: dem + rep,
      winnerCandidateId: dem >= rep ? 'd' : 'r',
      winnerVotes: dem >= rep ? dem : rep,
      candidateVotes: {'d': dem, 'r': rep},
    );

/// "Only See" narrows a US House race to one district: precincts outside it
/// count as having cast nothing, and every region built from them follows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MapStateStore mapState;
  late MapDataStore dataStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gerrymanderx_focus');
    PathProviderPlatform.instance = _TempPathProvider(tempDir.path);

    mapState = MapStateStore();
    dataStore = MapDataStore(ElectionStore(), mapState);
    // District 1 holds precincts 1 and 2; district 2 holds precinct 3.
    // County 10 straddles the two districts (precincts 2 and 3).
    dataStore.precinctVotes.value = {
      1: _votes(100, 50),
      2: _votes(40, 60),
      3: _votes(10, 90),
    };
    dataStore.cdPrecincts.value = {1: [1, 2], 2: [3]};
    dataStore.countyPrecincts.value = {10: [2, 3]};
    dataStore.activeElection.value = const ElectionContest(
      id: 3,
      office: MapDataStore.houseOffice,
      name: 'US House',
    );
  });

  tearDown(() => tempDir.delete(recursive: true));

  test('nothing changes while no district is picked', () {
    expect(dataStore.focusPrecincts.value, isNull);
    expect(
      dataStore.aggregateVotesForRegion(LayerType.state, 0)!.totalVotes,
      350,
    );
  });

  test('regions outside the picked district report zero votes', () {
    mapState.focusDistrictId.value = 1;

    expect(dataStore.focusPrecincts.value, {1, 2});

    final other = dataStore.aggregateVotesForRegion(
        LayerType.congressionalDistrict, 2)!;
    expect(other.totalVotes, 0);
    expect(other.winnerCandidateId, isNull);

    final outside = dataStore.aggregateVotesForRegion(LayerType.precinct, 3)!;
    expect(outside.totalVotes, 0);
    expect(outside.candidateVotes, isEmpty);
  });

  test('the picked district and what lies in it are untouched', () {
    mapState.focusDistrictId.value = 1;

    final picked = dataStore.aggregateVotesForRegion(
        LayerType.congressionalDistrict, 1)!;
    expect(picked.totalVotes, 250);
    expect(picked.candidateVotes, {'d': 140, 'r': 110});

    expect(
      dataStore.aggregateVotesForRegion(LayerType.precinct, 2)!.totalVotes,
      100,
    );
  });

  test('a county straddling the district keeps only its inside part', () {
    mapState.focusDistrictId.value = 1;

    final county = dataStore.aggregateVotesForRegion(LayerType.county, 10)!;
    expect(county.totalVotes, 100);
    expect(county.candidateVotes, {'d': 40, 'r': 60});

    expect(
      dataStore.aggregateVotesForRegion(LayerType.state, 0)!.totalVotes,
      250,
    );
  });

  group('a precinct split between districts', () {
    setUp(() {
      // Precinct 2 straddles the line: besides district 1's race it carries
      // 30 ballots for district 2's candidates 'd2' and 'r2'.
      dataStore.precinctVotes.value = {
        ...dataStore.precinctVotes.value,
        2: PrecinctVoteSummary(
          totalVotes: 130,
          winnerCandidateId: 'r',
          winnerVotes: 60,
          candidateVotes: {'d': 40, 'r': 60, 'd2': 20, 'r2': 10},
        ),
      };
      dataStore.candidates.value = const [
        Candidate(id: 'd', name: 'D1', district: '1'),
        Candidate(id: 'r', name: 'R1', district: '1'),
        Candidate(id: 'd2', name: 'D2', district: '2'),
        Candidate(id: 'r2', name: 'R2', district: '2'),
      ];
      RenderableCell district(int id) => RenderableCell(
            cell: GeoCell(
              id: id,
              name: 'District $id',
              layerType: LayerType.congressionalDistrict,
            ),
            path: Path(),
            exteriorPath: Path(),
            bounds: Rect.zero,
          );
      dataStore.cellIndex.value = {
        LayerType.congressionalDistrict: {1: district(1), 2: district(2)},
      };
    });

    test('lists only the picked district\'s candidates', () {
      mapState.focusDistrictId.value = 1;

      expect(dataStore.focusCandidateIds.value, {'d', 'r'});
      final precinct =
          dataStore.aggregateVotesForRegion(LayerType.precinct, 2)!;
      expect(precinct.candidateVotes, {'d': 40, 'r': 60});
      expect(precinct.totalVotes, 100);

      final county = dataStore.aggregateVotesForRegion(LayerType.county, 10)!;
      expect(county.candidateVotes, {'d': 40, 'r': 60});
    });

    test('keeps every candidate while no district is picked', () {
      expect(dataStore.focusCandidateIds.value, isNull);
      expect(
        dataStore.aggregateVotesForRegion(LayerType.precinct, 2)!.totalVotes,
        130,
      );
    });
  });

  test('a precinct reports its county and district by membership', () {
    RenderableCell cell(int id, String name, LayerType layer) =>
        RenderableCell(
          cell: GeoCell(id: id, name: name, layerType: layer),
          path: Path(),
          exteriorPath: Path(),
          bounds: Rect.zero,
        );
    dataStore.cellIndex.value = {
      LayerType.county: {10: cell(10, 'Blount', LayerType.county)},
      LayerType.congressionalDistrict: {
        1: cell(1, 'District 1', LayerType.congressionalDistrict),
        2: cell(2, 'District 2', LayerType.congressionalDistrict),
      },
    };

    final regions = dataStore.regionsOfPrecinct(3);
    expect(regions.counties, ['Blount']);
    expect(regions.districts, ['District 2']);

    // Precinct 1 lies in no county of this fixture.
    expect(dataStore.regionsOfPrecinct(1).counties, isEmpty);
    expect(dataStore.regionsOfPrecinct(1).districts, ['District 1']);
  });

  test('only applies to a US House contest', () {
    mapState.focusDistrictId.value = 1;
    dataStore.activeElection.value = const ElectionContest(
      id: 4,
      office: 'Governor',
      name: 'Governor',
    );

    expect(dataStore.focusPrecincts.value, isNull);
    expect(
      dataStore.aggregateVotesForRegion(LayerType.state, 0)!.totalVotes,
      350,
    );
  });

  test('loading another state drops the pick', () {
    mapState.focusDistrictId.value = 1;
    mapState.resetSelection();
    expect(mapState.focusDistrictId.value, isNull);
  });
}
