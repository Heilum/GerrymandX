import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:signals_flutter/signals_flutter.dart';

class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gerrymanderx_test');
    PathProviderPlatform.instance = _TempPathProvider(tempDir.path);
  });

  tearDown(() => tempDir.delete(recursive: true));

  const national = ElectionSubItem(name: 'National', isNational: true);
  const texas =
      ElectionSubItem(name: 'Texas', isNational: false, dbName: 'TX.db');

  /// Selecting a state in another election used to publish the new folder
  /// while the old election's sub-item was still current. Listeners loaded
  /// that pair — e.g. 2024 + 2020's `National` — and, for an election with no
  /// National.db, ended up with an empty map.
  test('publishes the folder and its sub-item as one selection', () async {
    final store = ElectionStore();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final seen = <(String?, String?)>[];
    final dispose = effect(() {
      seen.add((
        store.selectedElectionFolder.value,
        store.selectedSubItem.value?.name,
      ));
    });

    store.selectSubItem('2020-National-President', national);
    store.selectSubItem('2024-National-President', texas);
    dispose();

    expect(seen.last, ('2024-National-President', 'Texas'));
    expect(
      seen.where((s) => s.$1 == '2024-National-President' && s.$2 != 'Texas'),
      isEmpty,
      reason: 'the new folder must never be paired with the old sub-item',
    );
  });
}
