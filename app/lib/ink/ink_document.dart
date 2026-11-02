import 'package:flutter/foundation.dart';

import 'note_items.dart';
import 'stroke.dart';

/// One undoable step on a page.
abstract class _Action {
  _Action(this.page);

  final int page;

  void revert(InkDocument d);
  void apply(InkDocument d);
}

class _StrokeAction extends _Action {
  _StrokeAction(
    super.page, {
    this.added = const [],
    this.removed = const [],
    this.replaced = const [],
  });

  final List<Stroke> added;

  /// Removed strokes with their original index, in ascending index order.
  final List<({int index, Stroke stroke})> removed;

  /// Strokes changed in place (same id, same z-order): moved or recoloured.
  final List<({Stroke before, Stroke after})> replaced;

  @override
  void revert(InkDocument d) {
    final list = (d._pages[page] ??= []);
    for (final s in added) {
      list.removeWhere((e) => e.id == s.id);
    }
    for (final r in removed) {
      list.insert(r.index.clamp(0, list.length), r.stroke);
    }
    for (final r in replaced) {
      final i = list.indexWhere((e) => e.id == r.after.id);
      if (i >= 0) list[i] = r.before;
    }
  }

  @override
  void apply(InkDocument d) {
    final list = (d._pages[page] ??= []);
    for (final r in removed) {
      list.removeWhere((e) => e.id == r.stroke.id);
    }
    for (final s in added) {
      list.add(s);
    }
    for (final r in replaced) {
      final i = list.indexWhere((e) => e.id == r.before.id);
      if (i >= 0) list[i] = r.after;
    }
  }
}

class _ItemAction extends _Action {
  _ItemAction(super.page, {this.added, this.removed, this.before, this.after});

  final NoteItem? added;
  final ({int index, NoteItem item})? removed;
  final NoteItem? before;
  final NoteItem? after;

  @override
  void revert(InkDocument d) {
    final list = (d._items[page] ??= []);
    if (added != null) list.removeWhere((e) => e.id == added!.id);
    if (removed != null) {
      list.insert(removed!.index.clamp(0, list.length), removed!.item);
    }
    if (after != null) {
      final i = list.indexWhere((e) => e.id == after!.id);
      if (i >= 0) list[i] = before!;
    }
  }

  @override
  void apply(InkDocument d) {
    final list = (d._items[page] ??= []);
    if (removed != null) list.removeWhere((e) => e.id == removed!.item.id);
    if (added != null) list.add(added!);
    if (before != null) {
      final i = list.indexWhere((e) => e.id == before!.id);
      if (i >= 0) list[i] = after!;
    }
  }
}

/// All ink and note items of one PDF: per page, with undo/redo.
class InkDocument extends ChangeNotifier {
  InkDocument({
    Map<int, List<Stroke>>? pages,
    Map<int, List<NoteItem>>? items,
    int nextStrokeId = 1,
  }) : _pages = pages ?? {},
       _items = items ?? {},
       _nextId = nextStrokeId;

  final Map<int, List<Stroke>> _pages;
  final Map<int, List<NoteItem>> _items;
  final Map<int, ValueNotifier<int>> _revisions = {};
  final List<_Action> _undo = [];
  final List<_Action> _redo = [];
  int _nextId;

  // Erase gesture in progress: collected so one drag is one undo step.
  int? _erasePage;
  final List<({int index, Stroke stroke})> _eraseRemoved = [];

  /// Shared id counter for strokes and items.
  int get nextStrokeId => _nextId;
  int takeStrokeId() => _nextId++;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  Map<int, List<Stroke>> get pages => _pages;
  Map<int, List<NoteItem>> get items => _items;

  int get strokeCount => _pages.values.fold(0, (n, l) => n + l.length);

  List<Stroke> strokesOf(int page) => _pages[page] ?? const [];
  List<NoteItem> itemsOf(int page) => _items[page] ?? const [];

  /// Changes whenever the content of [page] changes; used to repaint that page only.
  ValueListenable<int> revisionOf(int page) =>
      _revisions.putIfAbsent(page, () => ValueNotifier(0));

  void _touch(int page) {
    final n = _revisions[page];
    if (n != null) n.value++;
    notifyListeners();
  }

  void _push(_Action a) {
    _undo.add(a);
    _redo.clear();
    _touch(a.page);
  }

  // ---- strokes ----

  void add(int page, Stroke stroke) {
    (_pages[page] ??= []).add(stroke);
    _push(_StrokeAction(page, added: [stroke]));
  }

  /// Adds several strokes as one undo step (used by duplicate).
  void addAll(int page, List<Stroke> strokes) {
    if (strokes.isEmpty) return;
    (_pages[page] ??= []).addAll(strokes);
    _push(_StrokeAction(page, added: List.of(strokes)));
  }

  /// Removes strokes by id as one undo step.
  void removeStrokes(int page, Set<int> ids) {
    final list = _pages[page];
    if (list == null) return;
    final removed = <({int index, Stroke stroke})>[];
    for (var i = 0; i < list.length; i++) {
      if (ids.contains(list[i].id)) removed.add((index: i, stroke: list[i]));
    }
    if (removed.isEmpty) return;
    list.removeWhere((s) => ids.contains(s.id));
    _push(_StrokeAction(page, removed: removed));
  }

  /// Replaces strokes in place by id (move, recolour) as one undo step.
  void replaceStrokes(int page, Map<int, Stroke> byId) {
    final list = _pages[page];
    if (list == null) return;
    final replaced = <({Stroke before, Stroke after})>[];
    for (var i = 0; i < list.length; i++) {
      final next = byId[list[i].id];
      if (next != null) {
        replaced.add((before: list[i], after: next));
        list[i] = next;
      }
    }
    if (replaced.isEmpty) return;
    _push(_StrokeAction(page, replaced: replaced));
  }

  // ---- note items (text, pins, tape) ----

  void addItem(int page, NoteItem item) {
    (_items[page] ??= []).add(item);
    _push(_ItemAction(page, added: item));
  }

  void removeItem(int page, int id) {
    final list = _items[page];
    if (list == null) return;
    final i = list.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final item = list.removeAt(i);
    _push(_ItemAction(page, removed: (index: i, item: item)));
  }

  void replaceItem(int page, NoteItem next) {
    final list = _items[page];
    if (list == null) return;
    final i = list.indexWhere((e) => e.id == next.id);
    if (i < 0) return;
    final before = list[i];
    list[i] = next;
    _push(_ItemAction(page, before: before, after: next));
  }

  // ---- eraser ----

  void beginErase(int page) {
    _erasePage = page;
    _eraseRemoved.clear();
  }

  /// Removes every stroke on the erase page that touches the circle at
  /// ([x], [y]) with [radius] (PDF points). Returns true if anything was removed.
  bool eraseAt(double x, double y, double radius) {
    final page = _erasePage;
    if (page == null) return false;
    final list = _pages[page];
    if (list == null || list.isEmpty) return false;
    var removedAny = false;
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].distanceTo(x, y) <= radius) {
        _eraseRemoved.add((index: i, stroke: list.removeAt(i)));
        removedAny = true;
      }
    }
    if (removedAny) _touch(page);
    return removedAny;
  }

  void endErase() {
    final page = _erasePage;
    if (page != null && _eraseRemoved.isNotEmpty) {
      // Indices were recorded while removing back-to-front; re-insertion
      // needs them front-to-back.
      final sorted = List.of(_eraseRemoved)
        ..sort((a, b) => a.index.compareTo(b.index));
      _undo.add(_StrokeAction(page, removed: sorted));
      _redo.clear();
      notifyListeners();
    }
    _erasePage = null;
    _eraseRemoved.clear();
  }

  // ---- history ----

  bool undo() {
    if (_undo.isEmpty) return false;
    final a = _undo.removeLast();
    a.revert(this);
    _redo.add(a);
    _touch(a.page);
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    final a = _redo.removeLast();
    a.apply(this);
    _undo.add(a);
    _touch(a.page);
    return true;
  }
}
