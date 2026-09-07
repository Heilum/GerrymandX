import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/core/utils/map_projection.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_zoom.dart';

void main() {
  group('MapProjection', () {
    // Alaska, with the western Aleutians unwrapped past -180°.
    final alaska = MapProjection.forExtent(
      minLat: 51.2,
      maxLat: 71.4,
      minLon: -187.7,
      maxLon: -130.0,
    );

    test('is conformal: a degree of longitude spans cos(lat) of a degree of latitude', () {
      for (final (lon, lat) in [(-150.0, 61.2), (-165.0, 54.0), (-145.0, 70.0), (-185.0, 52.0)]) {
        const step = 0.01;
        final o = alaska.project(lon, lat);
        final east = alaska.project(lon + step, lat);
        final north = alaska.project(lon, lat + step);
        final dx = (east - o).distance;
        final dy = (north - o).distance;
        expect(dx / dy, closeTo(math.cos(lat * math.pi / 180), 0.02),
            reason: 'at ($lon, $lat)');
        // Plain lon/lat drawing would give a ratio of 1 here.
        expect(dx / dy, lessThan(0.7));
      }
    });

    test('keeps the north up and units degree-sized', () {
      final south = alaska.project(-150, 60);
      final north = alaska.project(-150, 61);
      expect(north.dy, lessThan(south.dy));
      expect((south - north).distance, closeTo(1.0, 0.05));
      // The central meridian is vertical and centred on x = 0.
      expect(alaska.x(-158.85, 55), closeTo(0, 1e-9));
    });

    test('falls back to plain lon/lat when the cone degenerates', () {
      expect(MapProjection.identity.project(-100, 40), const Offset(-100, -40));
      expect(MapProjection.forPoints(const []).isIdentity, isTrue);
      expect(
        MapProjection.forExtent(minLat: -1, maxLat: 1, minLon: 0, maxLon: 2).isIdentity,
        isTrue,
      );
      expect(
        MapProjection.forExtent(minLat: double.nan, maxLat: 1, minLon: 0, maxLon: 2).isIdentity,
        isTrue,
      );
    });

    test('forPoints fits the extent of the given centres', () {
      final fromPoints = MapProjection.forPoints(const [
        (lat: 51.2, lon: -130.0),
        (lat: 71.4, lon: -187.7),
        (lat: 60.0, lon: -150.0),
      ]);
      expect(fromPoints.project(-150, 60), alaska.project(-150, 60));
    });
  });

  group('MapZoom.maxScaleFor', () {
    const canvas = Size(1800, 1000);

    test('lets a wide extent zoom further than a fixed multiple would', () {
      // Alaska: ~57 units wide fitted into 1800 px → 31.6 px/unit at 1x.
      const alaska = Rect.fromLTWH(-187, -71, 57, 20);
      expect(MapZoom.maxScaleFor(alaska, canvas), closeTo(253, 1));
      // Texas: ~11 units tall fitted into 1000 px → 91 px/unit at 1x.
      const texas = Rect.fromLTWH(-106, -36, 13, 11);
      expect(MapZoom.maxScaleFor(texas, canvas), closeTo(88, 1));
    });

    test('never drops below the base limit and never exceeds the cap', () {
      const rhodeIsland = Rect.fromLTWH(-71.9, -42.0, 0.8, 0.8);
      expect(MapZoom.maxScaleFor(rhodeIsland, canvas), MapZoom.baseMaxScale);
      // A tiny extent is already magnified at 1x, so the floor applies.
      const speck = Rect.fromLTWH(0, 0, 0.001, 0.001);
      expect(MapZoom.maxScaleFor(speck, canvas), MapZoom.baseMaxScale);
      // The whole globe fits at 5 px/unit; the cap keeps the limit sane.
      const globe = Rect.fromLTWH(-180, -90, 360, 180);
      expect(MapZoom.maxScaleFor(globe, canvas), MapZoom.maxScaleCap);
      expect(MapZoom.maxScaleFor(null, canvas), MapZoom.baseMaxScale);
      expect(MapZoom.maxScaleFor(Rect.zero, canvas), MapZoom.baseMaxScale);
    });
  });
}
