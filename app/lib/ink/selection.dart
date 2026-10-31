import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'ink_document.dart';
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

/// The strokes currently selected with the lasso, on a single page.
class SelectionController extends ChangeNotifier {
  SelectionController(this.document) {
    document.addListener(_prune);
  }

  final InkDocument document;
  int? _page;
  Set<int> _ids = {};

  int? get page => _page;
  Set<int> get ids => _ids;
  bool get active => _page != null && _ids.isNotEmpty;

  List<Stroke> get strokes => active
      ? document.strokesOf(_page!).where((s) => _ids.contains(s.id)).toList()
      : const [];

  /// Union of the selected strokes' bounds in PDF points, or null.
  Rect? get bounds {
    Rect? r;
    for (final s in strokes) {
      r = r == null ? s.bounds : r.expandToInclude(s.bounds);
    }
    return r;
  }

  void select(int page, Set<int> ids) {
    _page = ids.isEmpty ? null : page;
    _ids = ids;
    notifyListeners();
  }

  void clear() {
    if (_page == null && _ids.isEmpty) return;
    _page = null;
    _ids = {};
    notifyListeners();
  }

  /// Undo may remove selected strokes: forget the ones that are gone.
  void _prune() {
    if (!active) return;
    final alive = document.strokesOf(_page!).map((s) => s.id).toSet();
    final kept = _ids.intersection(alive);
    if (kept.length != _ids.length) select(_page!, kept);
  }

  void moveBy(double dx, double dy) {
    if (!active || (dx == 0 && dy == 0)) return;
    document.replaceStrokes(_page!, {
      for (final s in strokes) s.id: s.translated(dx, dy),
    });
  }

  void deleteSelected() {
    if (!active) return;
    final page = _page!;
    document.removeStrokes(page, _ids);
    clear();
  }

  /// Copies the selection a little to the side and selects the copies.
  void duplicateSelected({double offset = 14}) {
    if (!active) return;
    final copies = [
      for (final s in strokes)
        s.copyWith(id: document.takeStrokeId()).translated(offset, offset),
    ];
    final page = _page!;
    document.addAll(page, copies);
    select(page, copies.map((s) => s.id).toSet());
  }

  void recolor(int color) {
    if (!active) return;
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
