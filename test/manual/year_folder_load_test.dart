import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// End-to-end load of a real year-folder database, run by hand:
///
///     flutter test test/manual/year_folder_load_test.dart
///
/// Needs python-scripts/new_data/2024/KS-2024.db (built by
/// build_2024_state_dbs.py) and, for the comparison half, the legacy
/// python-scripts/data/output/2024-National-President/KS.db. Skipped when
/// either is missing.
class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

const _yearDb = 'python-scripts/new_data/2024/KS-2024.db';
const _legacyDb = 'python-scripts/data/output/2024-National-President/KS.db';
const _legacyManifest = 'python-scripts/data/elections.json';

Future<void> _waitUntil(bool Function() done,
    {Duration timeout = const Duration(minutes: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final haveYear = File(_yearDb).existsSync();
  final haveLegacy = File(_legacyDb).existsSync() && File(_legacyManifest).existsSync();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gerrymanderx_year');
    PathProviderPlatform.instance = _TempPathProvider(tempDir.path);
    final root = p.join(tempDir.path, 'GerrymanderX', 'Databases');

    final yearDir = Directory(p.join(root, '2024'))..createSync(recursive: true);
    File(_yearDb).copySync(p.join(yearDir.path, 'KS-2024.db'));
    File(p.join(yearDir.path, 'meta.json')).writeAsStringSync(json.encode({
      'name': '2024',
      'description': '2024 elections',
      'candidates': [],
      'parties': [],
      'dbs': [
        {'name': 'Kansas', 'url': 'https://files.xp-oncology.cn/gerrymander/2024/KS-2024.db'},
      ],
    }));

    if (haveLegacy) {
      final legacyDir = Directory(p.join(root, '2024-National-President'))
        ..createSync(recursive: true);
      File(_legacyDb).copySync(p.join(legacyDir.path, 'KS.db'));
      final manifest = json.decode(File(_legacyManifest).readAsStringSync()) as List;
      final entry = manifest.firstWhere((e) => e['name'] == '2024-National-President');
      File(p.join(legacyDir.path, 'meta.json')).writeAsStringSync(json.encode(entry));
    }
  });

  tearDown(() => tempDir.delete(recursive: true));

  test('loads a year folder, switches contest, compares with a legacy folder',
      () async {
    final electionStore = ElectionStore();
    final mapState = MapStateStore();
    final dataStore = MapDataStore(electionStore, mapState);

    await _waitUntil(() => electionStore.localDatabases.value.contains('2024'));
    final kansas = electionStore.localElectionSubItems.value['2024']!.single;
    expect(kansas.name, 'Kansas');
    expect(kansas.dbName, 'KS-2024.db');
    expect(kansas.stateCode, 'KS');

    electionStore.selectSubItem('2024', kansas);
    await _waitUntil(() =>
        dataStore.activeElection.value != null && !dataStore.isLoadingData.value);

    expect(dataStore.availableElections.value.map((c) => c.office),
        ['President', 'US House']);
    expect(dataStore.activeElection.value!.office, 'President');
    expect(dataStore.candidates.value.map((c) => c.name),
        containsAll(['Trump', 'Harris', 'Oliver', 'Kennedy']));
    expect(dataStore.parties.value.values.map((p) => p.name).toSet(),
        {'DEM', 'REP', 'LIB', 'IND'});
    expect(dataStore.precincts.value.length, 4193);
    final presidentTotal = dataStore.precinctVotes.value.values
        .fold<int>(0, (a, b) => a + b.totalVotes);
    expect(presidentTotal, 1327591);

    // Switch to the House contest: geometry stays, votes and candidates change.
    final versionBefore = dataStore.dataVersion.value;
    await dataStore.setOffice('US House');
    expect(dataStore.activeElection.value!.office, 'US House');
    expect(dataStore.dataVersion.value, greaterThan(versionBefore));
    expect(dataStore.precincts.value.length, 4193);
    expect(dataStore.candidates.value.map((c) => c.name),
        contains('Sharice Davids (District 3)'));
    final houseTotal = dataStore.precinctVotes.value.values
        .fold<int>(0, (a, b) => a + b.totalVotes);
    expect(houseTotal, 1305655);
    expect(electionStore.selectedOffice.value, 'US House');

    if (!haveLegacy) return;

    // The legacy folder holds the same state under another file name.
    expect(electionStore.foldersContainingState('KS', excluding: '2024'),
        ['2024-National-President']);
    expect(electionStore.dbNameFor('2024-National-President', 'KS'), 'KS.db');

    final comparisonBefore = dataStore.comparisonVersion.value;
    mapState.setFillMode(FillMode.singlePartyComparison);
    mapState.comparisonElectionFolder.value = '2024-National-President';
    await _waitUntil(() =>
        dataStore.comparisonVersion.value > comparisonBefore &&
        !dataStore.isLoadingComparison.value);
    expect(dataStore.comparisonRegionVotes.value[LayerType.county],
        isNotEmpty);
    expect(electionStore.partyNamesIn('2024-National-President'), contains('DEM'));

    dataStore.clearData();
  }, timeout: const Timeout(Duration(minutes: 5)), skip: !haveYear);
}
