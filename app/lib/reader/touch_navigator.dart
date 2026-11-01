import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../ink/tool_controller.dart';

/// View transform after a two-finger gesture that started with the fingers
/// centred on [f0], [d0] apart, and now centred on [f], [d] apart. The page
/// point that was under [f0] ends up under [f] and the zoom follows the
/// spread, so pinching and two-finger scrolling are one gesture.
Matrix4 pinchMatrix(Matrix4 start, Offset f0, double d0, Offset f, double d) {
  final s = d0 <= 0 ? 1.0 : d / d0;
  return Matrix4.translationValues(f.dx, f.dy, 0)
    ..multiply(Matrix4.diagonal3Values(s, s, 1))
    ..multiply(Matrix4.translationValues(-f0.dx, -f0.dy, 0))
    ..multiply(start);
}

/// View transform after a one-finger drag of [delta].
Matrix4 panMatrix(Matrix4 start, Offset delta) =>
    Matrix4.translationValues(delta.dx, delta.dy, 0)..multiply(start);

/// Wraps the PDF viewer. While a drawing tool is active the viewer's own
/// pan and zoom are off (so a finger or pen draws), and this widget moves
/// and zooms the view itself:
///  * two fingers anywhere on the viewer (even on two different pages)
///    pan and pinch-zoom;
///  * one finger pans when a pen does the drawing and finger drawing is off.
class TouchNavigator extends StatefulWidget {
  const TouchNavigator({
    super.key,
    required this.tools,
    required this.readView,
    required this.writeView,
    required this.child,
  });

  final ToolController tools;

  /// Current view transform (document to viewport), or null before the
  /// document is shown.
  final Matrix4? Function() readView;
  final void Function(Matrix4 view) writeView;
  final Widget child;

  @override
  State<TouchNavigator> createState() => _TouchNavigatorState();
}

class _TouchNavigatorState extends State<TouchNavigator> {
  final _pointers = <int, Offset>{};
  Matrix4? _start;
  bool _pinching = false;
  Offset _f0 = Offset.zero;
  double _d0 = 0;
  int? _panPointer;
  Offset _panFrom = Offset.zero;

  ({Offset focal, double distance}) _pair() {
    final ps = _pointers.values.take(2).toList();
    return (focal: (ps[0] + ps[1]) / 2, distance: (ps[0] - ps[1]).distance);
  }

  void _startPinch() {
    final m = widget.readView();
    if (m == null) return;
    final pair = _pair();
    _start = m.clone();
    _f0 = pair.focal;
    _d0 = pair.distance;
    _pinching = true;
    _panPointer = null;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    final tools = widget.tools;
    if (!tools.drawing) return;
    if (_pointers.length >= 2) {
      tools.setMultiTouch(true);
      _startPinch();
    } else if (e.kind == PointerDeviceKind.touch && tools.fingerScrolls) {
      final m = widget.readView();
      if (m != null) {
        _start = m.clone();
        _panPointer = e.pointer;
        _panFrom = e.localPosition;
      }
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final start = _start;
    if (start == null) return;
    if (_pinching && _pointers.length >= 2) {
      final pair = _pair();
      widget.writeView(pinchMatrix(start, _f0, _d0, pair.focal, pair.distance));
    } else if (_panPointer == e.pointer) {
      widget.writeView(panMatrix(start, e.localPosition - _panFrom));
    }
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_panPointer == e.pointer) _panPointer = null;
    if (_pinching) {
      if (_pointers.length >= 2) {
        _startPinch(); // a third finger lifted: continue with the new pair
      } else {
        _pinching = false;
      }
    }
    if (_pointers.isEmpty) {
      _start = null;
      widget.tools.setMultiTouch(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.child,
    );
  }
}
