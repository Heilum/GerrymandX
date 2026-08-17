import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Zoom behaviour shared by every map canvas.
class MapZoom {
  MapZoom._();

  static const minScale = 0.5;
  static const maxScale = 30.0;

  /// Scroll-wheel / trackpad zoom, centred on the pointer.
  static void applyScroll(
    TransformationController controller,
    PointerScrollEvent event,
  ) {
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
