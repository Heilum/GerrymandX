import 'dart:convert';
import 'package:flutter/painting.dart';

class GeoPathData {
  final Path path;
  final Rect bounds;

  GeoPathData({required this.path, required this.bounds});
}

class GeoJsonParser {
  // Parses a single GeoJSON string and returns a Path
  // Inverts Y (latitude) so it renders correctly on Flutter's Canvas (Y goes down).
  static GeoPathData parseGeoJson(String geoJsonString) {
    final Map<String, dynamic> geoJson = json.decode(geoJsonString);
    final path = Path();
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;

    void processPolygon(List<dynamic> polygon) {
      if (polygon.isEmpty) return;
      
      // Each polygon has rings. The first ring is the exterior boundary.
      for (var ring in polygon) {
        if (ring.isEmpty) continue;
        
        for (int i = 0; i < ring.length; i++) {
          final point = ring[i];
          final double x = (point[0] as num).toDouble();
          final double y = -(point[1] as num).toDouble(); // Invert Y for Flutter canvas
          
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;

          if (i == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        path.close();
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

    return GeoPathData(
      path: path, 
      bounds: Rect.fromLTRB(
        minX == double.infinity ? 0 : minX, 
        minY == double.infinity ? 0 : minY, 
        maxX == -double.infinity ? 0 : maxX, 
        maxY == -double.infinity ? 0 : maxY
      )
    );
  }
}
