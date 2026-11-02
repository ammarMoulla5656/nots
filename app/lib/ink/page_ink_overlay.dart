import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'ink_document.dart';
import 'item_painter.dart';
import 'note_items.dart';
import 'ruler.dart';
import 'selection.dart';
import 'shapes.dart';
import 'stroke.dart';
import 'stroke_painter.dart';
import 'tool_controller.dart';
import 'words.dart';

typedef CreateItemCallback = Future<void> Function(
  int page,
  ItemKind kind,
  Offset pointPt,
);
typedef EditItemCallback = Future<void> Function(int page, NoteItem item);

/// Called with a ready mark on PDF words; the screen adds it (asking for the
/// comment first when the style is "comment").
typedef CreateMarkCallback = Future<void> Function(int page, NoteItem draft);

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
    required this.viewChanged,
    required this.onCreateItem,
    required this.onEditItem,
    this.onCreateMark,
    this.loadWords,
  });

  final InkDocument document;
  final ToolController tools;
  final SelectionController selection;
  final int pageNumber;
  final double pageWidthPt;
  final double pageWidthPx;

  /// Fires when the zoom changes.
  final Listenable viewChanged;
  final CreateItemCallback onCreateItem;
  final EditItemCallback onEditItem;
  final CreateMarkCallback? onCreateMark;

  /// Words of this page's PDF text layer (for the word tool), or null when
  /// the page has no text layer support.
  final Future<List<WordBox>> Function()? loadWords;

  @override
  State<PageInkOverlay> createState() => _PageInkOverlayState();
}

class _PageInkOverlayState extends State<PageInkOverlay> {
  final _live = ValueNotifier<int>(0);
  Stroke? _current;
  int? _activePointer;
  int _strokeStartMs = 0;

  // Hold-still-to-snap for pen and highlighter strokes.
  Timer? _snapTimer;
  bool _snapped = false;
  static const _snapDelay = Duration(milliseconds: 500);

  // Shape tool: drag start.
  Offset? _shapeStart;

  // Lasso: loop being drawn, or a drag moving the selected strokes.
  List<Offset> _lasso = [];
  Offset? _dragFrom;
  Offset _dragOffset = Offset.zero;

  // Items: dragging one (stand-in preview in _itemPreview), or a tap that
  // may select it, edit it, or create a new one.
  NoteItem? _itemDrag;
  NoteItem? _itemPreview;
  bool _itemWasSelected = false;
  Offset _itemFrom = Offset.zero;
  Offset _itemOffset = Offset.zero;
  Offset? _tapPoint;
  bool _tapMoved = false;

  // Resizing the selection by a corner handle.
  int? _resizeHandle;
  Offset _resizeAnchor = Offset.zero;
  Offset _resizeGrab = Offset.zero;
  Rect _resizeRect0 = Rect.zero;
  NoteItem? _resizeItem0;
  double _resizeFactor = 1;

  // A tap on a button (delete / edit): swallow the rest of the gesture.
  bool _consumed = false;

  // Tape tool: dragging a new strip, or a tap that toggles an existing one.
  Offset? _tapeStart;
  Rect? _tapeRect;
  NoteItem? _tapeHit;

  // Word tool: the page's words and the range being marked.
  List<WordBox>? _words;
  Future<void>? _wordsLoading;
  int? _wordA;
  int? _wordB;

  // Several fingers: the page is being moved or zoomed, nothing draws until
  // every finger is lifted.
  int _downCount = 0;
  bool _multiTouch = false;

  // Two fingers inside the selection frame scale the selection.
  final _ptrPos = <int, Offset>{};
  bool _pinching = false;
  bool _pinchCommitted = false;
  double _pinch0 = 1;
  Offset _pinchAnchor = Offset.zero;
  NoteItem? _pinchItem0;

  // Ruler: one finger moves it, two rotate it, a stroke along its edge is
  // drawn straight.
  int? _rulerPtr;
  int? _rulerPtrB;
  Offset _rulerFrom = Offset.zero;
  Offset _rulerA0 = Offset.zero;
  Offset _rulerB0 = Offset.zero;
  Ruler? _rulerBase;
  Ruler? _rulerRef;
  int? _rulerSide;

  // The eraser removes boxes only after it has really moved, so a tap does
  // not delete them.
  double _eraseDist = 0;

  Offset? _lastErase;

  /// The current stroke erases because of the pen's eraser end or button.
  bool _stylusErasing = false;

  /// Where a hovering pen points (PDF points), for the preview ring.
  Offset? _hover;
  Timer? _hoverTimer;

  static bool _penErases(PointerEvent e) =>
      e.kind == PointerDeviceKind.invertedStylus ||
      (e.kind == PointerDeviceKind.stylus &&
          (e.buttons & (kPrimaryStylusButton | kSecondaryStylusButton)) != 0);

  /// A pen hovering above the screen: show where it will touch.
  void _onHover(PointerHoverEvent e) {
    if (e.kind != PointerDeviceKind.stylus &&
        e.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    _hover = _pt(e);
    _live.value++;
    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 700), () {
      _hover = null;
      if (mounted) _live.value++;
    });
  }

  /// Radius of the hover ring in PDF points.
  double get _hoverRadius {
    final t = widget.tools;
    if (t.mode == ToolMode.eraser) return _eraserRadius;
    return (t.width / 2).clamp(1.5, 30.0);
  }

  /// Screen pixels per PDF point. The overlay is laid out over the page as
  /// it appears on screen (already zoomed), so this includes the zoom.
  double get _scale => widget.pageWidthPx / widget.pageWidthPt;

  /// PDF points per screen pixel: keeps buttons and handles one size on
  /// screen at any zoom level.
  double get _unit => 1 / _scale;

  bool get _selectionHere =>
      widget.selection.active && widget.selection.page == widget.pageNumber;

  @override
  void initState() {
    super.initState();
    widget.tools.addListener(_onTools);
    if (widget.tools.mode == ToolMode.word ||
        widget.tools.mode == ToolMode.highlighter) {
      _ensureWords();
    }
  }

  @override
  void didUpdateWidget(PageInkOverlay old) {
    super.didUpdateWidget(old);
    if (old.tools != widget.tools) {
      old.tools.removeListener(_onTools);
      widget.tools.addListener(_onTools);
    }
  }

  @override
  void dispose() {
    widget.tools.removeListener(_onTools);
    _snapTimer?.cancel();
    _hoverTimer?.cancel();
    _live.dispose();
    super.dispose();
  }

  void _onTools() {
    final t = widget.tools;
    if (t.multiTouch && !_multiTouch) {
      // Another finger landed somewhere on the viewer: drop what this page
      // started and wait until all fingers are up.
      _multiTouch = true;
      if (_activePointer != null) _cancelGesture();
    } else if (!t.multiTouch && _downCount == 0) {
      _multiTouch = false;
    }
    if (t.mode == ToolMode.word || t.mode == ToolMode.highlighter) {
      _ensureWords();
    }
  }

  void _ensureWords() {
    final load = widget.loadWords;
    if (_words != null || _wordsLoading != null || load == null) return;
    _wordsLoading = load()
        .then((w) {
          _words = w;
        })
        .catchError((Object _) {
          _words = const [];
        });
  }

  bool _accepts(PointerDownEvent e) {
    if (_activePointer != null) return false;
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      widget.tools.markStylusSeen();
      return true;
    }
    // A finger while a pen does the drawing: it scrolls the page instead
    // (handled by the viewer-wide touch navigator).
    if (e.kind == PointerDeviceKind.touch && widget.tools.fingerScrolls) {
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
      if (kinds.contains(it.kind) && itemContains(it, p)) return it;
    }
    return null;
  }

  static bool _editable(NoteItem? it) => it != null && it.kind != ItemKind.tape;
  static bool _resizable(NoteItem? it) =>
      it == null || (it.kind != ItemKind.pin && it.kind != ItemKind.mark);

  SelectionGeometry? _geometry() {
    if (!_selectionHere) return null;
    final b = widget.selection.bounds;
    if (b == null) return null;
    final it = widget.selection.item;
    return SelectionGeometry(
      b,
      _unit,
      canEdit: _editable(it),
      canResize: _resizable(it),
    );
  }

  bool get _isScaling => _resizeHandle != null || _pinching;

  /// Eraser radius: about 9 screen pixels, whatever the zoom.
  double get _eraserRadius => (9 * _unit).clamp(2.0, 24.0);

  /// Bounds of the selection as it looks right now (mid move or resize).
  Rect? _liveFrame() {
    if (!_selectionHere) return null;
    final pv = _itemPreview;
    if (pv != null) return itemHitRect(pv);
    final b = widget.selection.bounds;
    if (b == null) return null;
    if (_isScaling) {
      final a = _resizeAnchor, f = _resizeFactor;
      return Rect.fromPoints(
        a + (b.topLeft - a) * f,
        a + (b.bottomRight - a) * f,
      );
    }
    if (_dragFrom != null) return b.shift(_dragOffset);
    return b;
  }

  SelectionTransform _strokeTransform() {
    if (_isScaling) {
      return SelectionTransform(factor: _resizeFactor, anchor: _resizeAnchor);
    }
    return SelectionTransform(offset: _dragOffset);
  }

  List<Rect> _previewRects() {
    final t = _tapeRect;
    if (t != null) return [t];
    final ws = _words, a = _wordA, b = _wordB;
    if (ws != null && a != null && b != null) {
      return lineRects(ws.sublist(math.min(a, b), math.max(a, b) + 1));
    }
    return const [];
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
    _itemPreview = null;
    _itemWasSelected = false;
    _itemOffset = Offset.zero;
    _tapPoint = null;
    _tapMoved = false;
    _resizeHandle = null;
    _resizeItem0 = null;
    _resizeFactor = 1;
    _consumed = false;
    _tapeStart = null;
    _tapeRect = null;
    _tapeHit = null;
    _wordA = null;
    _wordB = null;
    _lastErase = null;
    _stylusErasing = false;
    _eraseDist = 0;
    _rulerSide = null;
    _rulerRef = null;
    _rulerPtr = null;
  }

  void _cancelGesture() {
    final erasing =
        _activePointer != null &&
        (widget.tools.mode == ToolMode.eraser) &&
        _current == null;
    if (erasing) widget.document.endErase();
    _resetGesture();
    _activePointer = null;
    _live.value++;
  }

  void _down(PointerDownEvent e) {
    _downCount++;
    _ptrPos[e.pointer] = _pt(e);
    // A fresh touch after every finger was lifted: drawing is allowed again.
    if (_downCount == 1 && !widget.tools.multiTouch) _multiTouch = false;
    if (_downCount > 1) {
      if (_startTwoFinger(e)) return;
      _multiTouch = true;
      _cancelGesture();
      return;
    }
    if (_multiTouch || widget.tools.multiTouch || !_accepts(e)) return;
    _activePointer = e.pointer;
    _strokeStartMs = e.timeStamp.inMilliseconds;
    final tools = widget.tools;
    final p = _pt(e);

    final ruler = tools.ruler.value;
    if (ruler != null && ruler.page == widget.pageNumber && tools.drawing) {
      final writes = tools.mode == ToolMode.pen || tools.mode == ToolMode.highlighter;
      final side = writes && !_penErases(e)
          ? ruler.edgeSideNear(p, 12 * _unit)
          : null;
      if (side != null) {
        _rulerSide = side; // the stroke below follows this edge
        _rulerRef = ruler;
      } else if (ruler.contains(p)) {
        _rulerPtr = e.pointer;
        _rulerFrom = p;
        _rulerBase = ruler;
        _live.value++;
        return;
      }
    }

    if (_selectionHere && tools.mode != ToolMode.eraser) {
      final geo = _geometry();
      if (geo != null && _selectionDown(geo, p)) {
        _live.value++;
        return;
      }
    }

    switch (tools.mode) {
      case ToolMode.lasso:
        widget.selection.clear();
        _lasso = [p];
      case ToolMode.text || ToolMode.pin:
        final hit = _hitItem(p, {ItemKind.text, ItemKind.pin});
        if (hit != null) {
          _itemDrag = hit;
          _itemFrom = p;
          _itemOffset = Offset.zero;
          _itemWasSelected = false;
        } else {
          widget.selection.clear();
          _tapPoint = p;
        }
      case ToolMode.word:
        final mark = _hitItem(p, {ItemKind.mark});
        if (mark != null) {
          _itemDrag = mark;
          _itemFrom = p;
          _itemWasSelected = false;
        } else {
          widget.selection.clear();
          _ensureWords();
          final ws = _words;
          final i = ws == null ? null : wordAt(ws, p, tolerance: 3 * _unit);
          if (i != null) {
            _wordA = i;
            _wordB = i;
          }
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
        if (_penErases(e)) {
          _stylusErasing = true;
          widget.document.beginErase(widget.pageNumber);
          _erase(e);
          // Treated like the eraser tool until the pen lifts.
        } else {
          _current = Stroke(
            id: -1,
            tool: tools.strokeTool,
            color: tools.color,
            width: tools.width,
            points: [
              if (_rulerSide != null)
                () {
                  final q = _rulerRef!.snapToEdge(p, _rulerSide!);
                  return StrokePoint(q.dx, q.dy, 0.5, 0);
                }()
              else
                _point(e),
            ],
          );
        }
      case ToolMode.hand:
        break;
    }
    _live.value++;
  }

  /// A touch that lands on the selection's buttons, handles or body.
  /// Returns true when it was used.
  bool _selectionDown(SelectionGeometry geo, Offset p) {
    final sel = widget.selection;
    final page = widget.pageNumber;
    if (geo.hitClose(p)) {
      _consumed = true;
      sel.deleteSelected();
      return true;
    }
    if (geo.hitEdit(p)) {
      _consumed = true;
      final it = sel.item;
      if (it != null) unawaited(widget.onEditItem(page, it));
      return true;
    }
    final h = geo.hitHandle(p);
    if (h != null) {
      _resizeHandle = h;
      _resizeAnchor = geo.anchorFor(h);
      _resizeGrab = p;
      _resizeRect0 = geo.bounds;
      _resizeItem0 = sel.item;
      _resizeFactor = 1;
      return true;
    }
    if (geo.hitBody(p)) {
      final it = sel.item;
      if (it != null) {
        _itemDrag = it;
        _itemFrom = p;
        _itemOffset = Offset.zero;
        _itemWasSelected = true;
      } else {
        _dragFrom = p;
        _dragOffset = Offset.zero;
      }
      return true;
    }
    return false;
  }

  /// The second finger of a gesture: it may rotate the ruler or scale the
  /// selection. Returns true when it was taken (the page does not zoom).
  bool _startTwoFinger(PointerDownEvent e) {
    if (_downCount != 2 || _ptrPos.length != 2) return false;
    final tools = widget.tools;
    final pb = _ptrPos[e.pointer]!;

    final ruler = tools.ruler.value;
    if (_rulerPtr != null &&
        ruler != null &&
        ruler.contains(pb, slack: 24 * _unit)) {
      _rulerPtrB = e.pointer;
      _rulerBase = ruler;
      _rulerA0 = _ptrPos[_rulerPtr!]!;
      _rulerB0 = pb;
      tools.setSelectionPinch(true);
      return true;
    }

    if (_selectionHere && tools.mode != ToolMode.eraser) {
      final geo = _geometry();
      if (geo == null || !geo.canResize) return false;
      final zone = geo.frame.inflate(24 * _unit);
      final other = _ptrPos.entries.firstWhere((x) => x.key != e.pointer).value;
      if (!zone.contains(pb) || !zone.contains(other)) return false;
      _resetGesture();
      _activePointer = null;
      _pinching = true;
      _pinchCommitted = false;
      _pinch0 = math.max((pb - other).distance, 1e-3);
      _pinchAnchor = geo.bounds.center;
      _resizeAnchor = _pinchAnchor;
      _resizeFactor = 1;
      _pinchItem0 = widget.selection.item;
      tools.setSelectionPinch(true);
      _live.value++;
      return true;
    }
    return false;
  }

  void _pinchUpdate() {
    if (_ptrPos.length < 2) return;
    final ps = _ptrPos.values.take(2).toList();
    final f = ((ps[0] - ps[1]).distance / _pinch0).clamp(0.2, 12.0);
    _resizeFactor = f;
    final item = _pinchItem0;
    if (item != null) {
      final a = _pinchAnchor;
      final r = itemHitRect(item);
      _itemPreview = item.kind == ItemKind.tape
          ? item.copyWith(
              x: a.dx + (r.left - a.dx) * f,
              y: a.dy + (r.top - a.dy) * f,
              w: r.width * f,
              h: r.height * f,
            )
          : item.copyWith(
              fontSize: (item.fontSize * f).clamp(4.0, 400.0),
              w: (item.w > 0 ? item.w : NoteItem.defaultTextWidth) * f,
              x: a.dx + (r.left - a.dx) * f,
              y: a.dy + (r.top - a.dy) * f,
            );
    }
    _live.value++;
  }

  void _commitPinch() {
    _pinchCommitted = true;
    final pv = _itemPreview;
    if (pv != null) {
      widget.document.replaceItem(widget.pageNumber, pv);
    } else if (_pinchItem0 == null) {
      widget.selection.scaleStrokes(_resizeFactor, _pinchAnchor);
    }
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
    final snapped = snapShape([for (final p in c.points) Offset(p.x, p.y)]);
    if (snapped == null) return;
    _snapped = true;
    _current = c.copyWith(points: _asPoints(snapped));
    _live.value++;
  }

  void _move(PointerMoveEvent e) {
    _ptrPos[e.pointer] = _pt(e);
    if (_pinching) {
      _pinchUpdate();
      return;
    }
    if (_rulerPtrB != null) {
      final a1 = _ptrPos[_rulerPtr];
      final b1 = _ptrPos[_rulerPtrB];
      if (a1 != null && b1 != null) {
        widget.tools.ruler.value =
            _rulerBase!.twoFingers(_rulerA0, _rulerB0, a1, b1);
      }
      return;
    }
    if (e.pointer != _activePointer || _consumed) return;
    final p = _pt(e);
    if (_rulerPtr != null) {
      widget.tools.ruler.value =
          _rulerBase!.copyWith(center: _rulerBase!.center + (p - _rulerFrom));
      return;
    }
    if (_resizeHandle != null) {
      _resizeTo(p);
    } else if (_shapeStart != null) {
      _current = _current!.copyWith(
        points: _asPoints(shapePoints(widget.tools.shapeKind, _shapeStart!, p)),
      );
    } else if (_dragFrom != null) {
      _dragOffset = p - _dragFrom!;
    } else if (_lasso.isNotEmpty) {
      _lasso.add(p);
    } else if (_wordA != null) {
      final i = wordAt(_words!, p, tolerance: 3 * _unit);
      if (i != null) _wordB = i;
    } else if (_itemDrag != null) {
      _itemOffset = p - _itemFrom;
      // Marks belong to the PDF words: they never move.
      if (_itemDrag!.kind != ItemKind.mark &&
          _itemOffset.distance >= 8 * _unit) {
        _itemPreview = _itemDrag!.copyWith(
          x: _itemDrag!.x + _itemOffset.dx,
          y: _itemDrag!.y + _itemOffset.dy,
        );
      }
    } else if (_tapPoint != null) {
      // Dragging on empty page with the text/pin tool: not a tap any more.
      if ((p - _tapPoint!).distance > 8 * _unit) _tapMoved = true;
    } else if (_tapeStart != null) {
      _tapeRect = Rect.fromPoints(_tapeStart!, p);
    } else if (_current != null) {
      if (_snapped) return; // keep the clean shape while the pen is down
      if (_rulerSide != null) {
        // Along the ruler edge: a straight line from the first point.
        final end = _rulerRef!.snapToEdge(p, _rulerSide!);
        final pts = _current!.points;
        pts.removeRange(1, pts.length);
        pts.add(StrokePoint(end.dx, end.dy, 0.5, 1));
      } else {
        _current!.points.add(_point(e));
        _armSnap();
      }
    } else if (widget.tools.mode == ToolMode.eraser || _stylusErasing) {
      _erase(e);
      return;
    } else {
      return;
    }
    _live.value++;
  }

  /// Resize drag: strokes and text scale uniformly around the opposite
  /// corner; tape stretches freely.
  void _resizeTo(Offset p) {
    final a = _resizeAnchor;
    final item = _resizeItem0;
    if (item != null && item.kind == ItemKind.tape) {
      var r = Rect.fromPoints(a, p);
      if (r.width < 6 || r.height < 6) {
        r = Rect.fromLTWH(
          r.left,
          r.top,
          r.width < 6 ? 6 : r.width,
          r.height < 6 ? 6 : r.height,
        );
      }
      _itemPreview = item.copyWith(
        x: r.left,
        y: r.top,
        w: r.width,
        h: r.height,
      );
      return;
    }
    final base = (_resizeGrab - a).distance;
    if (base < 1e-6) return;
    final f = ((p - a).distance / base).clamp(0.1, 20.0);
    _resizeFactor = f;
    if (item != null) {
      final w0 = item.w > 0 ? item.w : NoteItem.defaultTextWidth;
      _itemPreview = item.copyWith(
        fontSize: (item.fontSize * f).clamp(4.0, 400.0),
        w: w0 * f,
        x: a.dx + (_resizeRect0.left - a.dx) * f,
        y: a.dy + (_resizeRect0.top - a.dy) * f,
      );
    }
  }

  void _erase(PointerEvent e) {
    final p = _pt(e);
    // Fast swipes produce few pointer events; test the points in between too
    // so the eraser cannot jump over a thin stroke.
    final from = _lastErase ?? p;
    _lastErase = p;
    _eraseDist += (p - from).distance;
    final steps = ((p - from).distance / 3).ceil().clamp(1, 400);
    for (var i = 1; i <= steps; i++) {
      final q = Offset.lerp(from, p, i / steps)!;
      widget.document.eraseAt(q.dx, q.dy, _eraserRadius);
      // Boxes and marks go only once the eraser has really been dragged.
      if (_eraseDist < 6 * _unit) continue;
      final hit = _hitItem(q, {ItemKind.tape, ItemKind.mark});
      if (hit != null && hit.text.isEmpty) {
        widget.document.removeItem(widget.pageNumber, hit.id);
      }
    }
  }

  /// A highlighter stroke that passes over text becomes a highlight of the
  /// words it touched (drawn under the letters, like the word highlighter);
  /// over pictures or empty page it stays a free stroke. Returns true when
  /// the stroke was turned into a word highlight.
  bool _snapHighlight(int page, Stroke cur) {
    if (cur.tool != InkTool.highlighter) return false;
    final words = _words;
    if (words == null || words.isEmpty) return false;
    final path = [for (final p in cur.points) Offset(p.x, p.y)];
    final idx = wordsAlongPath(words, path);
    if (idx.isEmpty) return false;
    final doc = widget.document;
    doc.addItem(
      page,
      NoteItem.mark(
        id: doc.takeStrokeId(),
        lineRects: lineRects([for (final i in idx) words[i]]),
        style: MarkStyle.highlight,
        color: cur.color,
        quote: idx.map((i) => words[i].text).join(' '),
      ),
    );
    return true;
  }

  /// A tap with the lasso: select the stroke or item under the finger.
  void _pick(Offset p) {
    final page = widget.pageNumber;
    final tol = 10 * _unit;
    final strokes = widget.document.strokesOf(page);
    for (var i = strokes.length - 1; i >= 0; i--) {
      if (strokes[i].distanceTo(p.dx, p.dy) <= tol) {
        widget.selection.select(page, {strokes[i].id});
        return;
      }
    }
    final it = _hitItem(p, ItemKind.values.toSet());
    if (it != null) {
      widget.selection.selectItem(page, it.id);
    } else {
      widget.selection.clear();
    }
  }

  void _up(PointerEvent e) {
    if (_downCount > 0) _downCount--;
    _ptrPos.remove(e.pointer);
    if (_pinching) {
      if (!_pinchCommitted) _commitPinch();
      if (_ptrPos.isEmpty) {
        _pinching = false;
        _pinchCommitted = false;
        _pinchItem0 = null;
        widget.tools.setSelectionPinch(false);
        _resetGesture();
      }
      _live.value++;
      return;
    }
    if (_rulerPtrB != null) {
      if (_ptrPos.isEmpty) {
        _rulerPtr = null;
        _rulerPtrB = null;
        _rulerBase = null;
        _activePointer = null;
        widget.tools.setSelectionPinch(false);
      }
      return;
    }
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    _snapTimer?.cancel();
    final doc = widget.document;
    final page = widget.pageNumber;
    final tools = widget.tools;

    if (_consumed || _rulerPtr != null) {
      // Button already acted on touch-down, or the ruler was only moved.
    } else if (_resizeHandle != null) {
      final pv = _itemPreview;
      if (pv != null) {
        doc.replaceItem(page, pv);
      } else {
        widget.selection.scaleStrokes(_resizeFactor, _resizeAnchor);
      }
    } else if (_dragFrom != null) {
      final off = _dragOffset;
      // Ignore accidental taps: less than 1 PDF point of movement.
      final moved = off.distance >= 1;
      widget.selection.moveBy(moved ? off.dx : 0, moved ? off.dy : 0);
    } else if (_lasso.isNotEmpty) {
      var length = 0.0;
      for (var i = 1; i < _lasso.length; i++) {
        length += (_lasso[i] - _lasso[i - 1]).distance;
      }
      if (length < 6 * _unit) {
        _pick(_lasso.first);
      } else {
        widget.selection.select(
          page,
          strokesInLasso(doc.strokesOf(page), _lasso),
        );
      }
    } else if (_wordA != null) {
      final ws = _words!;
      final a = math.min(_wordA!, _wordB!), b = math.max(_wordA!, _wordB!);
      final picked = ws.sublist(a, b + 1);
      final draft = NoteItem.mark(
        id: doc.takeStrokeId(),
        lineRects: lineRects(picked),
        style: tools.markStyle,
        color: tools.color,
        quote: picked.map((w) => w.text).join(' '),
      );
      final create = widget.onCreateMark;
      if (create != null) {
        unawaited(create(page, draft));
      } else {
        doc.addItem(page, draft);
      }
    } else if (_itemDrag != null) {
      final item = _itemDrag!;
      final pv = _itemPreview;
      if (pv == null) {
        // A tap: first tap selects, tapping the selected item edits it.
        if (_itemWasSelected) {
          unawaited(widget.onEditItem(page, item));
        } else {
          widget.selection.selectItem(page, item.id);
        }
      } else {
        doc.replaceItem(page, pv);
        widget.selection.selectItem(page, item.id);
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
          page,
          _tapeHit!.copyWith(revealed: !_tapeHit!.revealed),
        );
      }
    } else if (_shapeStart != null &&
        _current!.bounds.longestSide < _current!.width + 3) {
      // A tap with the shape tool draws nothing.
    } else if (_current != null && _snapHighlight(page, _current!)) {
      // The highlighter went over text: it became a highlight of those words.
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
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: StrokesPainter(
                strokes: () {
                  final all = widget.document.strokesOf(widget.pageNumber);
                  if (!_selectionHere || sel.ids.isEmpty) return all;
                  final hidden = sel.ids;
                  return all.where((s) => !hidden.contains(s.id)).toList();
                },
                scale: scale,
                repaint: Listenable.merge([revision, sel]),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: ItemsPainter(
              items: () => widget.document.itemsOf(widget.pageNumber),
              preview: () => _itemPreview,
              scale: scale,
              repaint: Listenable.merge([revision, _live]),
            ),
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
              transform: _strokeTransform,
              frame: _liveFrame,
              unit: () => _unit,
              canEdit: () => _editable(sel.item),
              canResize: () => _resizable(sel.item),
              lasso: () => _lasso,
              scale: scale,
              repaint: Listenable.merge([_live, sel, widget.viewChanged]),
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: _RulerPainter(
              ruler: () {
                final r = widget.tools.ruler.value;
                return r != null && r.page == widget.pageNumber ? r : null;
              },
              scale: scale,
              repaint: widget.tools.ruler,
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: _HoverPainter(
              at: () => _hover,
              radius: () => _hoverRadius,
              color: () => Color(widget.tools.color),
              scale: scale,
              repaint: _live,
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: _RectsPreviewPainter(
              rects: _previewRects,
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
              onPointerHover: _onHover,
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

/// Tape strip being dragged out, or the words being marked.
class _RectsPreviewPainter extends CustomPainter {
  _RectsPreviewPainter({
    required this.rects,
    required this.color,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<Rect> Function() rects;
  final Color Function() color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color().withValues(alpha: 0.4);
    for (final r in rects()) {
      canvas.drawRect(
        Rect.fromLTRB(
          r.left * scale,
          r.top * scale,
          r.right * scale,
          r.bottom * scale,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RectsPreviewPainter old) => old.scale != scale;
}

/// Ring where a hovering pen will touch, sized like the current tool.
class _HoverPainter extends CustomPainter {
  _HoverPainter({
    required this.at,
    required this.radius,
    required this.color,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Offset? Function() at;
  final double Function() radius;
  final Color Function() color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final p = at();
    if (p == null) return;
    final c = p * scale;
    final r = radius() * scale;
    canvas.drawCircle(c, r, Paint()..color = color().withValues(alpha: 0.25));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = color().withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_HoverPainter old) => old.scale != scale;
}

/// The ruler: a translucent band with centimetre marks along both edges.
class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.ruler,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Ruler? Function() ruler;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final r = ruler();
    if (r == null) return;
    canvas.save();
    canvas.translate(r.center.dx * scale, r.center.dy * scale);
    canvas.rotate(r.angle);
    final w = r.length * scale, h = r.thickness * scale;
    final body = Rect.fromCenter(center: Offset.zero, width: w, height: h);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(4 * scale)),
      Paint()..color = const Color(0xFF90CAF9).withValues(alpha: 0.42),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(4 * scale)),
      Paint()
        ..color = const Color(0xFF1565C0).withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 * scale,
    );
    final tick = Paint()
      ..color = const Color(0xFF0D47A1)
      ..strokeWidth = 0.7 * scale;
    final cm = Ruler.cm * scale;
    final n = (w / cm / 2).floor();
    for (var i = -n; i <= n; i++) {
      final x = i * cm;
      final big = i % 5 == 0;
      final len = (big ? 9 : 5) * scale;
      canvas.drawLine(Offset(x, h / 2), Offset(x, h / 2 - len), tick);
      canvas.drawLine(Offset(x, -h / 2), Offset(x, -h / 2 + len), tick);
      if (big && i != 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${i.abs()}',
            style: TextStyle(color: const Color(0xFF0D47A1), fontSize: 8 * scale),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, h / 2 - len - tp.height - scale));
        tp.dispose();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.scale != scale;
}
