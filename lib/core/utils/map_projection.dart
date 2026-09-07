import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Maps longitude/latitude onto the flat map coordinates every path, bound,
/// spatial index and hit test in the app works in.
///
/// Drawing raw degrees (x = longitude, y = -latitude) squashes everything
/// north of the equator: a degree of longitude spans cos(latitude) as much
/// ground as a degree of latitude, which at Alaska's 65° N is less than half.
/// Alaska came out more than twice as wide as it should be. A Lambert
/// conformal conic — the projection US state and national maps are drawn in —
/// keeps local shapes right and, with its two standard parallels placed
/// inside the data's latitude range, keeps area distortion small too.
///
/// Output units are scaled to be degree-sized (the sphere's radius is
/// 180/π), so extents, stroke widths and the outline grid in
/// [RegionOutline] keep the magnitudes the plain lon/lat drawing had.
/// y grows southward, matching the canvas.
class MapProjection {
  /// Plain longitude/latitude drawing, for data whose extent gives the conic
  /// nothing to work with (or none at all).
  static const identity = MapProjection._plateCarree();

  const MapProjection._plateCarree()
      : _n = 0,
        _f = 0,
        _rho0 = 0,
        _lon0 = 0;

  const MapProjection._conic(this._n, this._f, this._rho0, this._lon0);

  /// Cone constant; 0 means plate carrée.
  final double _n;
  final double _f;
  final double _rho0;

  /// Central meridian, radians.
  final double _lon0;

  static const _degrees = 180 / math.pi;
  static const _radians = math.pi / 180;

  bool get isIdentity => _n == 0;

  /// A conic fitted to the box [minLat]..[maxLat] × [minLon]..[maxLon]
  /// (degrees): standard parallels a sixth of the way in from each edge —
  /// the usual rule — and the central meridian through the middle.
  factory MapProjection.forExtent({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) {
    if (!minLat.isFinite || !maxLat.isFinite || !minLon.isFinite || !maxLon.isFinite) {
      return identity;
    }
    final span = maxLat - minLat;
    final lat1 = (minLat + span / 6) * _radians;
    final lat2 = (maxLat - span / 6) * _radians;
    final lat0 = (minLat + maxLat) / 2 * _radians;
    final lon0 = (minLon + maxLon) / 2 * _radians;

    final n = (lat2 - lat1).abs() < 1e-9
        ? math.sin(lat1)
        : math.log(math.cos(lat1) / math.cos(lat2)) /
            math.log(_halfTan(lat2) / _halfTan(lat1));
    // At the equator the cone degenerates into a cylinder.
    if (!n.isFinite || n.abs() < 1e-6) return identity;

    final f = math.cos(lat1) * math.pow(_halfTan(lat1), n) / n;
    final rho0 = f / math.pow(_halfTan(lat0), n);
    if (!f.isFinite || !rho0.isFinite) return identity;
    return MapProjection._conic(n, f, rho0, lon0);
  }

  /// Fitted to the latitude/longitude range of [points] (degrees, as
  /// (lat, lon) records); [identity] when there are none.
  factory MapProjection.forPoints(Iterable<({double lat, double lon})> points) {
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLon = double.infinity, maxLon = -double.infinity;
    for (final p in points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    if (minLat == double.infinity) return identity;
    return MapProjection.forExtent(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
  }

  /// tan(π/4 + φ/2)
  static double _halfTan(double lat) => math.tan(math.pi / 4 + lat / 2);

  /// Map x of ([lon], [lat]) in degrees.
  double x(double lon, double lat) {
    if (_n == 0) return lon;
    final rho = _f / math.pow(_halfTan(lat * _radians), _n);
    return rho * math.sin(_n * (lon * _radians - _lon0)) * _degrees;
  }

  /// Map y of ([lon], [lat]) in degrees; grows southward.
  double y(double lon, double lat) {
    if (_n == 0) return -lat;
    final rho = _f / math.pow(_halfTan(lat * _radians), _n);
    return (rho * math.cos(_n * (lon * _radians - _lon0)) - _rho0) * _degrees;
  }

  Offset project(double lon, double lat) => Offset(x(lon, lat), y(lon, lat));
}
