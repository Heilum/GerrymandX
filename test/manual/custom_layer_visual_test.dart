// Manual visual harness for the custom-layer editor.
//
// Loads the real election databases from the app sandbox, drives the UI, and
// writes PNGs to $GX_SHOTS. Skipped unless GX_VISUAL=1 is set, because it
// needs a downloaded state database and takes a while:
//
//   GX_VISUAL=1 GX_SHOTS=/tmp/shots flutter test test/manual/custom_layer_visual_test.dart
//
// The custom-layer repository is in-memory, so the user's real layers are
// never touched.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:gerrymanderx/core/theme/app_theme.dart';
import 'package:gerrymanderx/modules/elections/elections_tab.dart';
import 'package:gerrymanderx/providers/custom_layer_store.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/repositories/custom_layer_repository.dart';

class _RealDocs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _RealDocs(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  final enabled = Platform.environment['GX_VISUAL'] == '1';
  final shots = Platform.environment['GX_SHOTS'] ?? '/tmp/gx_shots';
  final home = Platform.environment['HOME']!;
  final docs = '$home/Library/Containers/com.example.gerrymanderx/Data/Documents';

  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('custom layer editor walkthrough', (tester) async {
    PathProviderPlatform.instance = _RealDocs(docs);
    Directory(shots).createSync(recursive: true);

    // Real I/O (fonts, sqlite) only completes inside runAsync.
    late CustomLayerRepository repo;
    await tester.runAsync(() async {
      // Real glyphs instead of Ahem boxes, so the screenshots are readable.
      // Best effort: the SDK's bundled Roboto stands in for the app font.
      final fonts = '${_flutterRoot()}/bin/cache/artifacts/material_fonts';
      if (Directory(fonts).existsSync()) {
        final roboto = FontLoader('SF Pro Text')
          ..addFont(_file('$fonts/Roboto-Regular.ttf'))
          ..addFont(_file('$fonts/Roboto-Bold.ttf'));
        await roboto.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(_file('$fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      }
      repo = await CustomLayerRepository.open(inMemoryDatabasePath);
    });

    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    late ElectionStore electionStore;
    late MapDataStore dataStore;
    late CustomLayerStore layerStore;
    final key = GlobalKey();

    await tester.runAsync(() async {
      electionStore = ElectionStore();
      final mapStore = MapStateStore();
      layerStore = CustomLayerStore(electionStore, mapStore,
          openRepository: () async => repo);
      dataStore = MapDataStore(electionStore, mapStore,
          customLayerStore: layerStore);

      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: electionStore),
          Provider.value(value: mapStore),
          Provider.value(value: layerStore),
          Provider.value(value: dataStore),
        ],
        child: RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: AppTheme.dark,
            darkTheme: AppTheme.dark,
            themeMode: ThemeMode.dark,
            debugShowCheckedModeBanner: false,
            home: const ElectionsTab(),
          ),
        ),
      ));

      // Wait for the sandbox scan, then pick 2024 / Texas.
      // ignore: avoid_print
      print('pumped; waiting for sandbox scan');
      await _until(() => electionStore.localElectionSubItems.value.isNotEmpty);
      // ignore: avoid_print
      print('scan done: ${electionStore.localDatabases.value}');
      final folder = electionStore.localDatabases.value
          .firstWhere((f) => f.contains('2024'));
      final tx = electionStore.localElectionSubItems.value[folder]!
          .firstWhere((s) => s.dbName == 'TX.db');
      electionStore.selectSubItem(folder, tx);
      // ignore: avoid_print
      print('selected $folder / ${tx.dbName}; loading');
      await _until(() => dataStore.precincts.value.isNotEmpty && !dataStore.isLoadingData.value,
          timeout: const Duration(minutes: 3));
      // ignore: avoid_print
      print('loaded ${dataStore.precincts.value.length} precincts');
      await _until(() => !layerStore.isLoading.value);
    });

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      late ui.Image image;
      await tester.runAsync(() async {
        image = await boundary.toImage(pixelRatio: 1.0);
      });
      final bytes = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png));
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('wrote $shots/$name.png');
    }

    await tester.pump(const Duration(milliseconds: 500));
    await shot('01_main');

    // [+] → new layer + editor.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('New custom layer'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Custom layer name'), findsOneWidget);
    await shot('02_editor_empty');

    // Add two groups.
    Future<void> addGroup() async {
      // Both taps inside runAsync: the async chain they start (dialog →
      // sqlite insert) must run in the real zone to complete.
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Add group cell'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('OK'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // ignore: avoid_print
      print('groups: ${layerStore.layers.value.first.groups.map((g) => g.title)}');
    }

    await addGroup();
    await addGroup();
    expect(find.text('G-1'), findsWidgets);
    expect(find.text('G-2'), findsWidgets);

    // Click around the map: several counties into G-2 (the selected one).
    final canvas = find.byType(InteractiveViewer).last;
    final rect = tester.getRect(canvas);
    Future<void> clickAt(double fx, double fy) async {
      await tester.runAsync(() async {
        await tester.tapAt(Offset(
          rect.left + rect.width * fx,
          rect.top + rect.height * fy,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 200));
    }

    await clickAt(0.55, 0.45);
    await clickAt(0.58, 0.48);
    await clickAt(0.52, 0.50);
    await clickAt(0.60, 0.42);
    // Select G-1 and give it a couple of counties.
    await tester.runAsync(() => tester.tap(find.text('G-1').first));
    await tester.pump(const Duration(milliseconds: 200));
    await clickAt(0.40, 0.55);
    await clickAt(0.43, 0.58);
    await clickAt(0.46, 0.55);
    await tester.pump(const Duration(milliseconds: 300));
    await shot('03_editor_groups');

    // Precinct level: switch interactive to precinct and click inside G-1.
    await tester.tap(find.text('precinct').last);
    // (that toggled visibility off if it was on; toggle logic keeps something)
    await tester.pump(const Duration(milliseconds: 200));
    await shot('04_editor_precinct_toggle');

    // Close the editor and look at the main map with the layer active.
    await tester.tap(find.byTooltip('Close'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 500));
    await shot('05_main_with_layer');
    for (final c in dataStore.customCells.value) {
      final m = c.exteriorPath.computeMetrics().fold<double>(0, (a, m) => a + m.length);
      // ignore: avoid_print
      print('group ${c.cell.id} ${c.cell.name}: bounds=${c.bounds} outlineLen=${m.toStringAsFixed(4)} '
          'color=${dataStore.customGroupColors.value[c.cell.id]} '
          'precincts=${dataStore.customPrecincts.value[c.cell.id]?.length}');
    }

    await tester.runAsync(() async {
      await layerStore.flush();
      await repo.close();
    });
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 10)));
}

/// FLUTTER_ROOT when set, else derived from the running `flutter_tester`
/// (…/bin/cache/artifacts/engine/<platform>/flutter_tester).
String _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  final exe = Platform.resolvedExecutable;
  final i = exe.indexOf('/bin/cache/');
  return i > 0 ? exe.substring(0, i) : '/Applications/flutter';
}

Future<ByteData> _file(String path) async {
  final bytes = await File(path).readAsBytes();
  return ByteData.sublistView(bytes);
}

Future<void> _until(bool Function() cond,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

class TimeoutException implements Exception {
  TimeoutException(this.message);
  final String message;
  @override
  String toString() => 'TimeoutException: $message';
}
