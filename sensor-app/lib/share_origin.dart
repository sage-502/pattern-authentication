import 'package:flutter/material.dart';

/// A non-empty screen-space anchor required by older share_plus on iOS 26.
Rect shareSheetOrigin(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is RenderBox &&
      renderObject.hasSize &&
      renderObject.size.width > 0 &&
      renderObject.size.height > 0) {
    final center = renderObject.localToGlobal(
        renderObject.size.center(Offset.zero));
    return Rect.fromCenter(center: center, width: 1, height: 1);
  }
  final size = MediaQuery.sizeOf(context);
  return Rect.fromLTWH(size.width / 2, size.height / 2, 1, 1);
}
