import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/widgets/map_view_panel.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';

class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

RenderableCell _cell(int id, LayerType layer, Rect rect) => RenderableCell(
      cell: GeoCell(id: id, name: '$layer $id', layerType: layer),
      path: Path()..addRect(rect),
      exteriorPath: Path()..addRect(rect),
      bounds: rect,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gerrymanderx_render');
    PathProviderPlatform.instance = _TempPathProvider(tempDir.path);
  });

  tearDown(() => tempDir.delete(recursive: true));

  /// Layers that are not the filled one skip recording their fill entirely.
  /// A [ui.PictureRecorder] that never had a Canvas attached throws on
  /// endRecording(), which took the whole map down rather than leaving that
  /// layer unfilled.
  testWidgets('draws with a visible layer that is not the filled one',
      (tester) async {
    final electionStore = ElectionStore();
    final mapState = MapStateStore();
    final dataStore = MapDataStore(electionStore, mapState);
    await tester.pump();

    const area = Rect.fromLTWH(0, 0, 10, 10);
    dataStore.counties.value = [_cell(1, LayerType.county, area)];
    dataStore.precincts.value = [
      _cell(2, LayerType.precinct, const Rect.fromLTWH(0, 0, 5, 10)),
      _cell(3, LayerType.precinct, const Rect.fromLTWH(5, 0, 5, 10)),
    ];
    dataStore.cellIndex.value = {
      LayerType.county: {1: dataStore.counties.value.first},
      LayerType.precinct: {
        for (final c in dataStore.precincts.value) c.cell.id: c
      },
    };
    dataStore.overallBounds.value = area;

    mapState.setVisibleLayers([LayerType.county, LayerType.precinct]);
    mapState.setFilledLayer(LayerType.county);

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider.value(value: electionStore),
        Provider.value(value: mapState),
        Provider.value(value: dataStore),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 200, height: 200, child: MapViewPanel()),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);

    // And switching the fill to the other layer keeps drawing.
    mapState.setFilledLayer(LayerType.precinct);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
