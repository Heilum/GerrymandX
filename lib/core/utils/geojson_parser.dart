import 'dart:typed_data';
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

class GeometryParser {
  // Parses WKB into raw coordinate lists (isolate-friendly, no dart:ui dependencies)
  static GeoCoordData parseWkbToCoords(Uint8List wkbBytes) {
    if (wkbBytes.isEmpty) {
      return GeoCoordData(rings: [], minX: 0, minY: 0, maxX: 0, maxY: 0);
    }

    final bd = ByteData.sublistView(wkbBytes);
    int offset = 0;

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;
    final List<List<List<double>>> allRings = [];

    void parsePolygon(Endian endian) {
      final numRings = bd.getUint32(offset, endian);
      offset += 4;
      for (int i = 0; i < numRings; i++) {
        final numPoints = bd.getUint32(offset, endian);
        offset += 4;
        final List<List<double>> ring = [];
        for (int p = 0; p < numPoints; p++) {
          final x = bd.getFloat64(offset, endian);
          offset += 8;
          final y = -bd.getFloat64(offset, endian); // Invert Y for Flutter canvas
          offset += 8;

          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;

          ring.add([x, y]);
        }
        allRings.add(ring);
      }
    }

    final byteOrder = bd.getUint8(offset);
    offset += 1;
    final endian = byteOrder == 1 ? Endian.little : Endian.big;
    final type = bd.getUint32(offset, endian) & 0xFF; // mask to get base type 2D
    offset += 4;

    if (type == 3) {
      // Polygon
      parsePolygon(endian);
    } else if (type == 6) {
      // MultiPolygon
      final numPolygons = bd.getUint32(offset, endian);
      offset += 4;
      for (int i = 0; i < numPolygons; i++) {
        final polyByteOrder = bd.getUint8(offset);
        offset += 1;
        final polyEndian = polyByteOrder == 1 ? Endian.little : Endian.big;
        final polyType = bd.getUint32(offset, polyEndian) & 0xFF;
        offset += 4;
        if (polyType == 3) {
          parsePolygon(polyEndian);
        }
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
    
    // Fallback bounds if empty
    Rect bounds = Rect.zero;
    if (data.rings.isNotEmpty) {
      bounds = Rect.fromLTRB(data.minX, data.minY, data.maxX, data.maxY);
    }
    
    return GeoPathData(
      path: path,
      bounds: bounds,
    );
  }
}
