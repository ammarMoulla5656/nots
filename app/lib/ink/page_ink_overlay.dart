import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'ink_document.dart';
import 'item_painter.dart';
import 'note_items.dart';
import 'selection.dart';
import 'shapes.dart';
import 'stroke.dart';
import 'stroke_painter.dart';
import 'tool_controller.dart';

typedef CreateItemCallback = Future<void> Function(
    int page, ItemKind kind, Offset pointPt);
typedef EditItemCallback = Future<void> Function(int page, NoteItem item);

/// Ink layer drawn above one PDF page. It fills the page rectangle; all
/// coordinates are stored in PDF points of that page.
class PageInkOverlay extends StatefulWidget {
  const PageInkOverlay({
    super.key,
    required this.document,
    required this.tools,
    required this.selection,
    required this.pageNumber,
    required this.pageWidthPt,
    required this.pageWidthPx,
    required this.onCreateItem,
    required this.onEditItem,
  });

  final InkDocument document;
  final ToolController tools;
  final SelectionController selection;
  final int pageNumber;
  final double pageWidthPt;
  final double pageWidthPx;
  final CreateItemCallback onCreateItem;
  final EditItemCallback onEditItem;

  @override
  State<PageInkOverlay> createState() => _PageInkOverlayState();
}

class _PageInkOverlayState extends State<PageInkOverlay> {
  final _live = ValueNotifier<int>(0);
  Stroke? _current;
  int? _activePointer;
  int _strokeStartMs = 0;
  bool _sawStylus = false;

  // Hold-still-to-snap for pen and highlighter strokes.
  Timer? _snapTimer;
  bool _snapped = false;
  static const _snapDelay = Duration(milliseconds: 500);

  // Shape tool: drag start.
  Offset? _shapeStart;

  // Lasso: loop being drawn, or a drag moving the selection.
  List<Offset> _lasso = [];
  Offset? _dragFrom;
  Offset _dragOffset = Offset.zero;

  // Text and pin tools: dragging an item, or a tap that may create one.
  NoteItem? _itemDrag;
  Offset _itemFrom = Offset.zero;
  Offset _itemOffset = Offset.zero;
  Offset? _tapPoint;
  bool _tapMoved = false;

  // Tape tool: dragging a new strip, or a tap that toggles an existing one.
  Offset? _tapeStart;
  Rect? _tapeRect;
  NoteItem? _tapeHit;

  // Two fingers mean pinch-zoom: drop what the first finger started and
  // ignore input until every finger is lifted.
  int _downCount = 0;
  bool _multiTouch = false;

  double get _scale => widget.pageWidthPx / widget.pageWidthPt;

  bool get _selectionHere =>
      widget.selection.active && widget.selection.page == widget.pageNumber;

  @override
  void dispose() {
    _snapTimer?.cancel();
    _live.dispose();
    super.dispose();
  }

  bool _accepts(PointerDownEvent e) {
    if (_activePointer != null) return false;
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      _sawStylus = true;
      return true;
    }
    if (e.kind == PointerDeviceKind.touch &&
        _sawStylus &&
        !widget.tools.fingerDraws) {
      return false;
    }
    return true;
  }

  double _pressure(PointerEvent e) {
    if (e.kind != PointerDeviceKind.stylus &&
        e.kind != PointerDeviceKind.invertedStylus) {
      return 0.5;
    }
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    return ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
  }

  Offset _pt(PointerEvent e) =>
      Offset(e.localPosition.dx / _scale, e.localPosition.dy / _scale);

  StrokePoint _point(PointerEvent e) => StrokePoint(
        e.localPosition.dx / _scale,
        e.localPosition.dy / _scale,
        _pressure(e),
        e.timeStamp.inMilliseconds - _strokeStartMs,
      );

  List<StrokePoint> _asPoints(List<Offset> pts) => [
        for (var i = 0; i < pts.length; i++)
          StrokePoint(pts[i].dx, pts[i].dy, 0.5, i),
      ];

  NoteItem? _hitItem(Offset p, Set<ItemKind> kinds) {
    final items = widget.document.itemsOf(widget.pageNumber);
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (kinds.contains(it.kind) && itemHitRect(it).contains(p)) return it;
    }
    return null;
  }

  void _resetGesture() {
    _snapTimer?.cancel();
    _snapped = false;
    _current = null;
    _shapeStart = null;
    _lasso = [];
    _dragFrom = null;
    _dragOffset = Offset.zero;
    _itemDrag = null;
    _itemOffset = Offset.zero;
    _tapPoint = null;
    _tapMoved = false;
    _tapeStart = null;
    _tapeRect = null;
    _tapeHit = null;
    _lastErase = null;
  }

  void _cancelGesture() {
    final erasing = _activePointer != null &&
        (widget.tools.mode == ToolMode.eraser) &&
        _current == null;
    if (erasing) widget.document.endErase();
    _resetGesture();
    _activePointer = null;
    _live.value++;
  }

  void _down(PointerDownEvent e) {
    _downCount++;
    if (_downCount > 1) {
      _multiTouch = true;
      _cancelGesture();
      return;
    }
    if (_multiTouch || !_accepts(e)) return;
    _activePointer = e.pointer;
    _strokeStartMs = e.timeStamp.inMilliseconds;
    final tools = widget.tools;
    final p = _pt(e);

    switch (tools.mode) {
      case ToolMode.lasso:
        final box = widget.selection.bounds;
        final slack = 10 / _scale;
        if (_selectionHere && box != null && box.inflate(slack).contains(p)) {
          _dragFrom = p;
          _dragOffset = Offset.zero;
        } else {
          widget.selection.clear();
          _lasso = [p];
        }
      case ToolMode.text || ToolMode.pin:
        final hit = _hitItem(p, {ItemKind.text, ItemKind.pin});
        if (hit != null) {
          _itemDrag = hit;
          _itemFrom = p;
          _itemOffset = Offset.zero;
        } else {
          _tapPoint = p;
        }
      case ToolMode.tape:
        _tapeStart = p;
        _tapeHit = _hitItem(p, {ItemKind.tape});
      case ToolMode.shape:
        _shapeStart = p;
        _current = Stroke(
          id: -1,
          tool: InkTool.pen,
          color: tools.color,
          width: tools.width,
          points: _asPoints([p, p]),
        );
      case ToolMode.eraser:
        widget.document.beginErase(widget.pageNumber);
        _erase(e);
      case ToolMode.pen || ToolMode.highlighter:
        if (e.kind == PointerDeviceKind.invertedStylus) {
          widget.document.beginErase(widget.pageNumber);
          _erase(e);
          // Treated like the eraser tool until the pen lifts.
        } else {
          _current = Stroke(
            id: -1,
            tool: tools.strokeTool,
            color: tools.color,
            width: tools.width,
            points: [_point(e)],
          );
        }
      case ToolMode.hand:
        break;
    }
    _live.value++;
  }

  bool get _canSnap {
    final t = widget.tools;
    if (!t.snapShapes) return false;
    return t.mode == ToolMode.highlighter ||
        (t.mode == ToolMode.pen && t.penKind != InkTool.calligraphy);
  }

  void _armSnap() {
    _snapTimer?.cancel();
    if (!_canSnap) return;
    _snapTimer = Timer(_snapDelay, _trySnap);
  }

  /// The pen stayed still: turn the stroke into a clean shape if it clearly
  /// is one.
  void _trySnap() {
    final c = _current;
    if (c == null || _snapped) return;
    final snapped =
        snapShape([for (final p in c.points) Offset(p.x, p.y)]);
    if (snapped == null) return;
    _snapped = true;
    _current = c.copyWith(points: _asPoints(snapped));
    _live.value++;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    final p = _pt(e);
    if (_shapeStart != null) {
      _current = _current!.copyWith(
        points: _asPoints(
            shapePoints(widget.tools.shapeKind, _shapeStart!, p)),
      );
    } else if (_dragFrom != null) {
      _dragOffset = p - _dragFrom!;
    } else if (_lasso.isNotEmpty) {
      _lasso.add(p);
    } else if (_itemDrag != null) {
      _itemOffset = p - _itemFrom;
    } else if (_tapPoint != null) {
      // Dragging on empty page with the text/pin tool: not a tap any more.
      if ((p - _tapPoint!).distance > 4) _tapMoved = true;
    } else if (_tapeStart != null) {
      _tapeRect = Rect.fromPoints(_tapeStart!, p);
    } else if (_current != null) {
      if (_snapped) return; // keep the clean shape while the pen is down
      _current!.points.add(_point(e));
      _armSnap();
    } else {
      _erase(e);
      return;
    }
    _live.value++;
  }

  Offset? _lastErase;

  void _erase(PointerEvent e) {
    final p = _pt(e);
    // Fast swipes produce few pointer events; test the points in between too
    // so the eraser cannot jump over a thin stroke.
    final from = _lastErase ?? p;
    _lastErase = p;
    final steps = ((p - from).distance / 3).ceil().clamp(1, 400);
    for (var i = 1; i <= steps; i++) {
      final q = Offset.lerp(from, p, i / steps)!;
      // Eraser radius: 6 PDF points, whatever the zoom.
      widget.document.eraseAt(q.dx, q.dy, 6);
      final hit = _hitItem(q, ItemKind.values.toSet());
      if (hit != null) widget.document.removeItem(widget.pageNumber, hit.id);
    }
  }

  void _up(PointerEvent e) {
    if (_downCount > 0) _downCount--;
    if (_downCount == 0) _multiTouch = false;
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    _snapTimer?.cancel();
    final doc = widget.document;
    final page = widget.pageNumber;
    final tools = widget.tools;

    if (_dragFrom != null) {
      final off = _dragOffset;
      // Ignore accidental taps: less than 1 PDF point of movement.
      final moved = off.distance >= 1;
      widget.selection.moveBy(moved ? off.dx : 0, moved ? off.dy : 0);
    } else if (_lasso.isNotEmpty) {
      widget.selection
          .select(page, strokesInLasso(doc.strokesOf(page), _lasso));
    } else if (_itemDrag != null) {
      final item = _itemDrag!;
      final off = _itemOffset;
      if (off.distance < 3) {
        unawaited(widget.onEditItem(page, item));
      } else {
        doc.replaceItem(
            page, item.copyWith(x: item.x + off.dx, y: item.y + off.dy));
      }
    } else if (_tapPoint != null) {
      if (!_tapMoved) {
        final kind = tools.mode == ToolMode.pin ? ItemKind.pin : ItemKind.text;
        unawaited(widget.onCreateItem(page, kind, _tapPoint!));
      }
    } else if (_tapeStart != null) {
      final r = _tapeRect;
      if (r != null && r.width >= 6 && r.height >= 6) {
        doc.addItem(
          page,
          NoteItem(
            id: doc.takeStrokeId(),
            kind: ItemKind.tape,
            x: r.left,
            y: r.top,
            w: r.width,
            h: r.height,
            color: tools.color,
          ),
        );
      } else if (_tapeHit != null) {
        doc.replaceItem(
            page, _tapeHit!.copyWith(revealed: !_tapeHit!.revealed));
      }
    } else if (_shapeStart != null &&
        _current!.bounds.longestSide < _current!.width + 3) {
      // A tap with the shape tool draws nothing.
    } else if (_current != null) {
      final cur = _current!;
      doc.add(
        page,
        Stroke(
          id: doc.takeStrokeId(),
          tool: cur.tool,
          color: cur.color,
          width: cur.width,
          points: cur.points,
        ),
      );
    } else {
      doc.endErase();
    }
    _resetGesture();
    _live.value++;
  }

  @override
  Widget build(BuildContext context) {
    final scale = _scale;
    final sel = widget.selection;
    final revision = widget.document.revisionOf(widget.pageNumber);
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: StrokesPainter(
              strokes: () {
                final all = widget.document.strokesOf(widget.pageNumber);
                if (!_selectionHere) return all;
                final hidden = sel.ids;
                return all.where((s) => !hidden.contains(s.id)).toList();
              },
              scale: scale,
              repaint: Listenable.merge([revision, sel]),
            ),
          ),
        ),
        CustomPaint(
          painter: ItemsPainter(
            items: () => widget.document.itemsOf(widget.pageNumber),
            drag: () => _itemDrag == null
                ? null
                : (id: _itemDrag!.id, offset: _itemOffset),
            scale: scale,
            repaint: Listenable.merge([revision, _live]),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: LiveStrokePainter(
              current: () => _current,
              scale: scale,
              repaint: _live,
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: SelectionPainter(
              selected: () => _selectionHere ? sel.strokes : const [],
              offset: () => _dragOffset,
              lasso: () => _lasso,
              scale: scale,
              repaint: Listenable.merge([_live, sel]),
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: _RectPreviewPainter(
              rect: () => _tapeRect,
              color: () => Color(widget.tools.color),
              scale: scale,
              repaint: _live,
            ),
          ),
        ),
        ListenableBuilder(
          listenable: widget.tools,
          builder: (context, _) {
            if (!widget.tools.drawing) return const SizedBox.shrink();
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: const SizedBox.expand(),
            );
          },
        ),
      ],
    );
  }
}

/// Outline of the tape strip while it is being dragged out.
class _RectPreviewPainter extends CustomPainter {
  _RectPreviewPainter({
    required this.rect,
    required this.color,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Rect? Function() rect;
  final Color Function() color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect();
    if (r == null) return;
    final scaled = Rect.fromLTRB(
        r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);
    canvas.drawRect(scaled, Paint()..color = color().withValues(alpha: 0.5));
  }

  @override
  bool shouldRepaint(_RectPreviewPainter old) => old.scale != scale;
}
