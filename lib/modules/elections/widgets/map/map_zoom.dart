import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Zoom behaviour shared by every map canvas.
class MapZoom {
  MapZoom._();

  static const minScale = 0.5;

  /// The least any map can be zoomed, whatever its extent.
  static const baseMaxScale = 30.0;

  /// A fixed multiple of the fitted view is a poor limit: the fitted view of
  /// Alaska is a fifth the scale of Texas's, so the same multiple left its
  /// precincts a fifth the size. Instead the limit is set so that every map
  /// reaches this many pixels per map unit — a degree of latitude, roughly
  /// 111 km — about 70 px per kilometre, enough for city-block precincts.
  static const maxPixelsPerUnit = 8000.0;

  /// Ceiling on the computed limit, for tiny extents on huge canvases.
  static const maxScaleCap = 400.0;

  /// The zoom limit for a map of [bounds] fitted into [canvas].
  static double maxScaleFor(Rect? bounds, Size canvas) {
    if (bounds == null || bounds.isEmpty || canvas.isEmpty) return baseMaxScale;
    final fit = math.min(
      canvas.width / bounds.width,
      canvas.height / bounds.height,
    );
    if (!fit.isFinite || fit <= 0) return baseMaxScale;
    return (maxPixelsPerUnit / fit).clamp(baseMaxScale, maxScaleCap);
  }

  /// Scroll-wheel / trackpad zoom, centred on the pointer.
  static void applyScroll(
    TransformationController controller,
    PointerScrollEvent event, {
    double maxScale = baseMaxScale,
  }) {
    final direction = event.scrollDelta.dy > 0 ? -1.0 : 1.0;
    const zoomFactor = 0.1;
    final currentScale = controller.value.getMaxScaleOnAxis();
    final newScale = (currentScale * (1.0 + direction * zoomFactor))
        .clamp(minScale, maxScale);
    final scaleDelta = newScale / currentScale;

    final matrix = controller.value.clone();
    final focalInChild = matrix.clone()..invert();
    final focalLocal =
        MatrixUtils.transformPoint(focalInChild, event.localPosition);

    matrix.translateByDouble(focalLocal.dx, focalLocal.dy, 0, 1);
    matrix.scaleByDouble(scaleDelta, scaleDelta, 1, 1);
    matrix.translateByDouble(-focalLocal.dx, -focalLocal.dy, 0, 1);

    controller.value = matrix;
  }

  /// Stroke widths are divided by the zoom when a layer is recorded, so the
  /// recording has to know the zoom level or borders scale with the
  /// InteractiveViewer transform. Bucketing to powers of two keeps the number
  /// of re-records small — at most one per doubling.
  static double bucketFor(double scale) {
    if (!scale.isFinite || scale <= 1.0) return 1.0;
    return math.pow(2, (math.log(scale) / math.ln2).round()).toDouble();
  }
}
