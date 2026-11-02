import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'ink_document.dart';
import 'item_painter.dart';
import 'note_items.dart';
import 'stroke.dart';

/// Ray-casting test: is ([x], [y]) inside the closed polygon [poly]?
bool pointInPolygon(double x, double y, List<Offset> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > y) != (b.dy > y) &&
        x < (b.dx - a.dx) * (y - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// Ids of strokes with at least half of their points inside [lasso].
Set<int> strokesInLasso(List<Stroke> strokes, List<Offset> lasso) {
  if (lasso.length < 3) return {};
  final ids = <int>{};
  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    var inside = 0;
    for (final p in s.points) {
      if (pointInPolygon(p.x, p.y, lasso)) inside++;
    }
    if (inside * 2 >= s.points.length) ids.add(s.id);
  }
  return ids;
}

/// Where the selection frame, its delete/edit buttons and its corner handles
/// are, in PDF points. [unit] is how many PDF points one screen pixel is, so
/// buttons keep the same finger-friendly size at any zoom level.
class SelectionGeometry {
  SelectionGeometry(this.bounds, this.unit,
      {required this.canEdit, required this.canResize});

  final Rect bounds;
  final double unit;
  final bool canEdit;
  final bool canResize;

  Rect get frame => bounds.inflate(3 * unit);

  /// Small round buttons just above the frame's top-right corner.
  static const buttonRadiusPx = 10.0;

  Offset get closeCenter =>
      Offset(frame.right - 6 * unit, frame.top - 15 * unit);
  Offset get editCenter =>
      Offset(frame.right - 30 * unit, frame.top - 15 * unit);

  /// Frame corners: top-left, top-right, bottom-right, bottom-left.
  List<Offset> get corners =>
      [frame.topLeft, frame.topRight, frame.bottomRight, frame.bottomLeft];

  /// Corner of [bounds] opposite to handle [i]; it stays fixed while resizing.
  Offset anchorFor(int i) => [
        bounds.topLeft,
        bounds.topRight,
        bounds.bottomRight,
        bounds.bottomLeft,
      ][(i + 2) % 4];

  // Touch targets are larger than what is drawn, so the small buttons and
  // handles stay easy to hit with a finger.
  bool hitClose(Offset p) => (p - closeCenter).distance <= 13 * unit;
  bool hitEdit(Offset p) => canEdit && (p - editCenter).distance <= 13 * unit;

  int? hitHandle(Offset p) {
    if (!canResize) return null;
    final c = corners;
    for (var i = 0; i < 4; i++) {
      if ((p - c[i]).distance <= 12 * unit) return i;
    }
    return null;
  }

  bool hitBody(Offset p) => frame.inflate(6 * unit).contains(p);
}

/// What is selected on one page: lasso-selected strokes, or one text box,
/// pin or tape strip.
class SelectionController extends ChangeNotifier {
  SelectionController(this.document) {
    document.addListener(_prune);
  }

  final InkDocument document;
  int? _page;
  Set<int> _ids = {};
  int? _itemId;

  int? get page => _page;
  Set<int> get ids => _ids;
  int? get itemId => _itemId;
  bool get active => _page != null && (_ids.isNotEmpty || _itemId != null);

  NoteItem? get item {
    if (_page == null || _itemId == null) return null;
    for (final it in document.itemsOf(_page!)) {
      if (it.id == _itemId) return it;
    }
    return null;
  }

  List<Stroke> get strokes => _page != null && _ids.isNotEmpty
      ? document.strokesOf(_page!).where((s) => _ids.contains(s.id)).toList()
      : const [];

  /// Bounds of the selection in PDF points, or null.
  Rect? get bounds {
    final it = item;
    if (it != null) return itemHitRect(it);
    Rect? r;
    for (final s in strokes) {
      r = r == null ? s.bounds : r.expandToInclude(s.bounds);
    }
    return r;
  }

  void select(int page, Set<int> ids) {
    _page = ids.isEmpty ? null : page;
    _ids = ids;
    _itemId = null;
    notifyListeners();
  }

  void selectItem(int page, int id) {
    _page = page;
    _ids = {};
    _itemId = id;
    notifyListeners();
  }

  void clear() {
    if (_page == null && _ids.isEmpty && _itemId == null) return;
    _page = null;
    _ids = {};
    _itemId = null;
    notifyListeners();
  }

  /// Undo may remove what is selected: forget what is gone.
  void _prune() {
    if (!active) return;
    if (_itemId != null) {
      if (item == null) clear();
      return;
    }
    final alive = document.strokesOf(_page!).map((s) => s.id).toSet();
    final kept = _ids.intersection(alive);
    if (kept.length != _ids.length) select(_page!, kept);
  }

  void moveBy(double dx, double dy) {
    if (_ids.isEmpty || (dx == 0 && dy == 0)) return;
    document.replaceStrokes(_page!, {
      for (final s in strokes) s.id: s.translated(dx, dy),
    });
  }

  /// Resizes the selected strokes by [factor] around [anchor] (one undo step).
  void scaleStrokes(double factor, Offset anchor) {
    if (_ids.isEmpty || factor == 1) return;
    document.replaceStrokes(_page!, {
      for (final s in strokes) s.id: s.scaled(factor, anchor),
    });
  }

  void deleteSelected() {
    if (!active) return;
    final page = _page!;
    if (_itemId != null) {
      document.removeItem(page, _itemId!);
    } else {
      document.removeStrokes(page, _ids);
    }
    clear();
  }

  /// Copies the selection a little to the side and selects the copies.
  void duplicateSelected({double offset = 14}) {
    if (!active) return;
    final page = _page!;
    final it = item;
    if (it != null) {
      final copy = it.copyWith(
          id: document.takeStrokeId(), x: it.x + offset, y: it.y + offset);
      document.addItem(page, copy);
      selectItem(page, copy.id);
      return;
    }
    final copies = [
      for (final s in strokes)
        s.copyWith(id: document.takeStrokeId()).translated(offset, offset),
    ];
    document.addAll(page, copies);
    select(page, copies.map((s) => s.id).toSet());
  }

  /// Colour of the selection (of its first stroke or the item), or null.
  int? get currentColor {
    final it = item;
    if (it != null) return it.color;
    final st = strokes;
    return st.isEmpty ? null : st.first.color;
  }

  void recolor(int color) {
    if (!active) return;
    final it = item;
    if (it != null) {
      document.replaceItem(_page!, it.copyWith(color: color));
      return;
    }
    document.replaceStrokes(_page!, {
      for (final s in strokes) s.id: s.copyWith(color: color),
    });
  }

  @override
  void dispose() {
    document.removeListener(_prune);
    super.dispose();
  }
}
