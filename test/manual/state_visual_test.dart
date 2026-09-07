// Manual visual harness for a single state database.
//
// Renders the borders of every layer of GX_DB (a state .db, or National.db
// for the state layer) straight through BaseMapPainter — no election
// manifest or download plumbing — and writes PNGs to GX_SHOTS. Skipped unless
// GX_VISUAL=1 is set:
//
//   GX_VISUAL=1 GX_DB=python-scripts/data/output/2024-National-President/AK.db \
//     GX_SHOTS=/tmp/shots flutter test test/manual/state_visual_test.dart
//
// GX_ZOOM_LON / GX_ZOOM_LAT (degrees) add a second image zoomed to the map's
// limit around that point, to check how far precincts can be magnified.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:gerrymanderx/core/utils/geojson_parser.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_zoom.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

void main() {
  final env = Platform.environment;
  final enabled = env['GX_VISUAL'] == '1';
  final shots = env['GX_SHOTS'] ?? '/tmp/gx_shots';
  final dbPath = env['GX_DB'] ?? '';
  final zoomLon = double.tryParse(env['GX_ZOOM_LON'] ?? '');
  final zoomLat = double.tryParse(env['GX_ZOOM_LAT'] ?? '');

  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('renders a state database', (tester) async {
    Directory(shots).createSync(recursive: true);
    final dataStore = MapDataStore(ElectionStore(), MapStateStore());
    const size = Size(1800, 1000);

    await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final tables = {
        for (final row in await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
          row['name'] as String
      };
      final layers = <LayerType, String>{
        if (tables.contains('states')) LayerType.state: 'states',
        if (tables.contains('counties')) LayerType.county: 'counties',
        if (tables.contains('congressional_districts'))
          LayerType.congressionalDistrict: 'congressional_districts',
        if (tables.contains('precincts')) LayerType.precinct: 'precincts',
      };

      final raw = <LayerType, List<GeoCell>>{};
      for (final entry in layers.entries) {
        final rows = await db.query(entry.value,
            columns: ['id', 'name', 'boundary', 'center_lat', 'center_lon']);
        raw[entry.key] = [for (final r in rows) GeoCell.fromMap(r, entry.key)];
      }
      await db.close();

      final all = [for (final cells in raw.values) ...cells];
      final projection = MapDataStore.projectionForTest(all);
      dataStore.projection = projection;
      print('projection identity: ${projection.isIdentity}');

      Rect? bounds;
      final renderables = <LayerType, List<RenderableCell>>{};
      for (final entry in raw.entries) {
        final list = <RenderableCell>[];
        for (final cell in entry.value) {
          final wkb = cell.boundaryWkb;
          if (wkb == null) continue;
          final pathData = GeometryParser.coordsToPath(
              GeometryParser.parseWkbToCoords(wkb, projection: projection));
          if (pathData.bounds.isEmpty) continue;
          bounds = bounds == null
              ? pathData.bounds
              : bounds.expandToInclude(pathData.bounds);
          list.add(RenderableCell(
            cell: cell,
            path: pathData.path,
            exteriorPath: pathData.exteriorPath,
            bounds: pathData.bounds,
          ));
        }
        renderables[entry.key] = list;
        print('${entry.key}: ${list.length} cells');
      }
      dataStore.states.value = renderables[LayerType.state] ?? [];
      dataStore.counties.value = renderables[LayerType.county] ?? [];
      dataStore.congressionalDistricts.value =
          renderables[LayerType.congressionalDistrict] ?? [];
      dataStore.precincts.value = renderables[LayerType.precinct] ?? [];
      dataStore.overallBounds.value = bounds;
      print('bounds: $bounds');
      final maxScale = MapZoom.maxScaleFor(bounds, size);
      print('max zoom: $maxScale');

      Future<void> shoot(String name, double zoom, Offset? focus) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1A1A2E));
        if (focus != null) {
          // Zoom about the map point under [focus], like InteractiveViewer.
          final t = MapTransform.fit(bounds!, size);
          final px = Offset(focus.dx * t.scale + t.offsetX,
              focus.dy * t.scale + t.offsetY);
          canvas.translate(size.width / 2, size.height / 2);
          canvas.scale(zoom, zoom);
          canvas.translate(-px.dx, -px.dy);
        }
        BaseMapPainter(
          dataStore: dataStore,
          visibleLayers: layers.keys.toList(),
          fillMode: FillMode.none,
          interactiveScale: MapZoom.bucketFor(zoom),
          drawFill: false,
          drawBorder: true,
        ).paint(canvas, size);
        final image = await recorder
            .endRecording()
            .toImage(size.width.toInt(), size.height.toInt());
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        print('wrote $shots/$name.png');
      }

      await shoot('fit', 1, null);
      if (zoomLon != null && zoomLat != null) {
        await shoot('zoom_max', maxScale, projection.project(zoomLon, zoomLat));
        await shoot('zoom_30', 30, projection.project(zoomLon, zoomLat));
      }
    });
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 5)));
}
