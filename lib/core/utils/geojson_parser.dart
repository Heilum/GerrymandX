import 'dart:typed_data';
import 'package:flutter/painting.dart';

class GeoPathData {
  final Path path;         // Full path for fill (evenOdd)
  final Path exteriorPath; // Exterior path ONLY for clean borders
  final Rect bounds;

  GeoPathData({
    required this.path,
    required this.exteriorPath,
    required this.bounds,
  });
}

class GeoCoordData {
  final List<List<List<double>>> exteriorRings;
  final List<List<List<double>>> interiorRings;
  final double minX, minY, maxX, maxY;

  GeoCoordData({
    required this.exteriorRings,
    required this.interiorRings,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });
}

class GeometryParser {
  // Parses WKB into raw coordinate lists (isolate-friendly, no dart:ui dependencies)
  static GeoCoordData parseWkbToCoords(Uint8List wkbBytes) {
    if (wkbBytes.isEmpty) {
      return GeoCoordData(
        exteriorRings: [],
        interiorRings: [],
        minX: 0,
        minY: 0,
        maxX: 0,
        maxY: 0,
      );
    }

    final bd = ByteData.sublistView(wkbBytes);
    int offset = 0;

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;
    final List<List<List<double>>> exteriorRings = [];
    final List<List<List<double>>> interiorRings = [];

    void parsePolygon(Endian endian, bool hasZ, bool hasM) {
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
          if (hasZ) offset += 8;
          if (hasM) offset += 8;

          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;

          ring.add([x, y]);
        }
        if (i == 0) {
          exteriorRings.add(ring);
        } else {
          interiorRings.add(ring);
        }
      }
    }

    void skipPoints(Endian endian, int strideBytes) {
      final numPoints = bd.getUint32(offset, endian);
      offset += 4;
      offset += numPoints * strideBytes;
    }

    void parseGeometry() {
      if (offset + 5 > bd.lengthInBytes) return;
      final byteOrder = bd.getUint8(offset);
      offset += 1;
      final endian = byteOrder == 1 ? Endian.little : Endian.big;
      final rawType = bd.getUint32(offset, endian);
      offset += 4;

      final bool hasSrid = (rawType & 0x20000000) != 0;
      final int baseType2d = rawType & 0xFF;
      final int isoType = rawType & 0xFFFF;

      final bool hasZ = (rawType & 0x80000000) != 0 ||
          (isoType >= 1000 && isoType < 2000) ||
          (isoType >= 3000 && isoType < 4000);

      final bool hasM = (rawType & 0x40000000) != 0 ||
          (isoType >= 2000 && isoType < 3000) ||
          (isoType >= 3000 && isoType < 4000);

      if (hasSrid) {
        offset += 4; // Skip SRID uint32
      }

      final stride = 16 + (hasZ ? 8 : 0) + (hasM ? 8 : 0);

      if (baseType2d == 3) {
        // Polygon
        parsePolygon(endian, hasZ, hasM);
      } else if (baseType2d >= 4 && baseType2d <= 7) {
        // MultiPoint / MultiLineString / MultiPolygon / GeometryCollection.
        // Each member carries its own header, so recursion handles them all.
        // GeometryCollection matters in practice: repairing a self-intersecting
        // polygon can yield one, with the area in its polygonal members and
        // zero-width slivers in the rest.
        final numGeometries = bd.getUint32(offset, endian);
        offset += 4;
        for (int i = 0; i < numGeometries; i++) {
          parseGeometry();
        }
      } else if (baseType2d == 1) {
        // Point — skip, but keep the offset aligned for later members.
        offset += stride;
      } else if (baseType2d == 2) {
        // LineString — skip.
        skipPoints(endian, stride);
      } else {
        // Unknown type: the body length is unknown, so stop rather than
        // misread the remaining bytes as coordinates.
        offset = bd.lengthInBytes;
      }
    }

    try {
      parseGeometry();
    } catch (_) {}

    return GeoCoordData(
      exteriorRings: exteriorRings,
      interiorRings: interiorRings,
      minX: minX == double.infinity ? 0 : minX,
      minY: minY == double.infinity ? 0 : minY,
      maxX: maxX == -double.infinity ? 0 : maxX,
      maxY: maxY == -double.infinity ? 0 : maxY,
    );
  }

  // Converts coordinate data to a dart:ui Path (must run on main thread)
  static GeoPathData coordsToPath(GeoCoordData data) {
    final fullPath = Path();
    fullPath.fillType = PathFillType.evenOdd;
    final exteriorPath = Path();

    for (final ring in data.exteriorRings) {
      if (ring.isEmpty) continue;
      exteriorPath.moveTo(ring[0][0], ring[0][1]);
      fullPath.moveTo(ring[0][0], ring[0][1]);
      for (int i = 1; i < ring.length; i++) {
        exteriorPath.lineTo(ring[i][0], ring[i][1]);
        fullPath.lineTo(ring[i][0], ring[i][1]);
      }
      exteriorPath.close();
      fullPath.close();
    }

    for (final ring in data.interiorRings) {
      if (ring.isEmpty) continue;
      fullPath.moveTo(ring[0][0], ring[0][1]);
      for (int i = 1; i < ring.length; i++) {
        fullPath.lineTo(ring[i][0], ring[i][1]);
      }
      fullPath.close();
    }

    Rect bounds = Rect.zero;
    if (data.exteriorRings.isNotEmpty || data.interiorRings.isNotEmpty) {
      bounds = Rect.fromLTRB(data.minX, data.minY, data.maxX, data.maxY);
    }

    return GeoPathData(
      path: fullPath,
      exteriorPath: exteriorPath,
      bounds: bounds,
    );
  }
}
