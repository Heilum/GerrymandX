import 'dart:convert';
import 'package:flutter/painting.dart';

class GeoPathData {
  final Path path;
  final Rect bounds;

  GeoPathData({required this.path, required this.bounds});
}

class GeoCoordData {
  final List<List<List<double>>> rings; // [ring[point[x, y]]]
  final double minX, minY, maxX, maxY;

  GeoCoordData({required this.rings, required this.minX, required this.minY, required this.maxX, required this.maxY});
}

class GeoJsonParser {
  // Parses a single GeoJSON string and returns a Path
  // Inverts Y (latitude) so it renders correctly on Flutter's Canvas (Y goes down).
  static GeoPathData parseGeoJson(String geoJsonString) {
    final coordData = parseGeoJsonToCoords(geoJsonString);
    return coordsToPath(coordData);
  }

  // Parses GeoJSON into raw coordinate lists (isolate-friendly, no dart:ui dependencies)
  static GeoCoordData parseGeoJsonToCoords(String geoJsonString) {
    final Map<String, dynamic> geoJson = json.decode(geoJsonString);
    final List<List<List<double>>> allRings = [];
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;

    void processPolygon(List<dynamic> polygon) {
      if (polygon.isEmpty) return;
      
      for (var ring in polygon) {
        if (ring.isEmpty) continue;
        
        final List<List<double>> parsedRing = [];
        for (int i = 0; i < ring.length; i++) {
          final point = ring[i];
          final double x = (point[0] as num).toDouble();
          final double y = -(point[1] as num).toDouble(); // Invert Y for Flutter canvas
          
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;

          parsedRing.add([x, y]);
        }
        allRings.add(parsedRing);
      }
    }

    final type = geoJson['type'];
    if (type == 'Polygon') {
      processPolygon(geoJson['coordinates']);
    } else if (type == 'MultiPolygon') {
      for (var polygon in geoJson['coordinates']) {
        processPolygon(polygon);
      }
    }

    return GeoCoordData(
      rings: allRings,
      minX: minX == double.infinity ? 0 : minX,
      minY: minY == double.infinity ? 0 : minY,
      maxX: maxX == -double.infinity ? 0 : maxX,
      maxY: maxY == -double.infinity ? 0 : maxY,
    );
  }

  // Converts coordinate data to a dart:ui Path (must run on main thread)
  static GeoPathData coordsToPath(GeoCoordData data) {
    final path = Path();
    for (final ring in data.rings) {
      if (ring.isEmpty) continue;
      path.moveTo(ring[0][0], ring[0][1]);
      for (int i = 1; i < ring.length; i++) {
        path.lineTo(ring[i][0], ring[i][1]);
      }
      path.close();
    }
    return GeoPathData(
      path: path,
      bounds: Rect.fromLTRB(data.minX, data.minY, data.maxX, data.maxY),
    );
  }
}
