import 'dart:io';

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

PrecinctVoteSummary _votes(int dem, int rep, {int population = 0}) =>
    PrecinctVoteSummary(
      totalVotes: dem + rep,
      winnerCandidateId: dem >= rep ? 'd' : 'r',
      winnerVotes: dem >= rep ? dem : rep,
      candidateVotes: {'d': dem, 'r': rep},
      population: population,
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
      1: _votes(100, 50, population: 300),
      2: _votes(40, 60, population: 200),
      3: _votes(10, 90, population: 100),
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
    expect(other.population, 100, reason: 'people stay, ballots go');

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
    expect(county.population, 300);

    expect(
      dataStore.aggregateVotesForRegion(LayerType.state, 0)!.totalVotes,
      250,
    );
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
