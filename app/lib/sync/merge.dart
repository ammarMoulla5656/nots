import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ink/note_items.dart';
import '../ink/stroke.dart';

/// What a stroke looks like, without its id: the same line has the same key
/// on every device, whatever id each one gave it.
String _strokeKey(Stroke s) {
  final b = StringBuffer('${s.tool.index}|${s.color}|${s.width}');
  for (final q in s.points) {
    b.write('|${q.x},${q.y},${q.pressure},${q.t}');
  }
  return b.toString();
}

String _itemKey(NoteItem i) => [
  i.kind.index,
  i.x,
  i.y,
  i.w,
  i.h,
  i.text,
  i.color,
  i.fontSize,
  i.revealed,
  i.style.index,
  i.rects.map((r) => '${r.left},${r.top},${r.width},${r.height}').join(';'),
  i.quote,
  i.wordFrom,
  i.wordTo,
].join('|');

/// Three-way merge of one page: what either side added stays, what either
/// side removed goes, and what both have stays once. Changing something is
/// removing the old and adding the new, so two changes of the same thing
/// both survive.
List<T> _mergeList<T>(
  List<T> base,
  List<T> mine,
  List<T> theirs,
  String Function(T) key,
) {
  final inBase = base.map(key).toSet();
  final inMine = mine.map(key).toSet();
  final inTheirs = theirs.map(key).toSet();
  return [
    for (final e in mine)
      if (inTheirs.contains(key(e)) || !inBase.contains(key(e))) e,
    for (final e in theirs)
      if (!inMine.contains(key(e)) && !inBase.contains(key(e))) e,
  ];
}

/// The content of one page.
class PageVersion {
  const PageVersion(this.strokes, this.items);

  final List<Stroke> strokes;
  final List<NoteItem> items;

  bool sameAs(PageVersion o) =>
      setEquals(
        strokes.map(_strokeKey).toSet(),
        o.strokes.map(_strokeKey).toSet(),
      ) &&
      setEquals(items.map(_itemKey).toSet(), o.items.map(_itemKey).toSet());
}

/// [mine] and [theirs] merged, what they started from being [base].
PageVersion mergePage(PageVersion base, PageVersion mine, PageVersion theirs) =>
    PageVersion(
      _mergeList(base.strokes, mine.strokes, theirs.strokes, _strokeKey),
      _mergeList(base.items, mine.items, theirs.items, _itemKey),
    );

/// The three versions of a page changed on both sides.
class PageSides {
  const PageSides(this.mine, this.theirs, this.merged);

  final PageVersion mine;
  final PageVersion theirs;
  final PageVersion merged;
}

typedef _Ink = ({
  Map<int, List<Stroke>> pages,
  int nextStrokeId,
  Map<int, List<NoteItem>> items,
});

const _Ink _noInk = (pages: {}, nextStrokeId: 1, items: {});

_Ink _decode(Uint8List? bytes) =>
    bytes == null ? _noInk : StrokeCodec.decodeDocument(bytes);

PageVersion _pageOf(_Ink d, int n) =>
    PageVersion(d.pages[n] ?? const [], d.items[n] ?? const []);

/// Merges two versions of a book's writing that both started from [base]
/// (null when they share no history: everything on both sides is kept).
/// [ink] is the result, or null when there is no writing at all. [sides] has
/// the pages both changed, differently: what the user may want to choose on.
({Uint8List? ink, Map<int, PageSides> sides}) mergeBook(
  Uint8List? base,
  Uint8List? mine,
  Uint8List? theirs,
) {
  if (mine == null && theirs == null) return (ink: null, sides: const {});
  final b = _decode(base), m = _decode(mine), t = _decode(theirs);
  final merged = <int, PageVersion>{};
  final both = <int>{};
  for (final n in {
    ...m.pages.keys,
    ...t.pages.keys,
    ...m.items.keys,
    ...t.items.keys,
  }) {
    final (was, a, c) = (_pageOf(b, n), _pageOf(m, n), _pageOf(t, n));
    merged[n] = mergePage(was, a, c);
    if (!a.sameAs(was) && !c.sameAs(was) && !a.sameAs(c)) both.add(n);
  }
  // Each device counts ids on its own: the same id may mean two things.
  var next = [m.nextStrokeId, t.nextStrokeId].reduce((a, c) => a > c ? a : c);
  final seen = <int>{};
  int fresh(int id) {
    if (seen.add(id)) return id;
    while (!seen.add(next)) {
      next++;
    }
    return next++;
  }

  final pages = <int, List<Stroke>>{};
  final items = <int, List<NoteItem>>{};
  for (final e in merged.entries) {
    pages[e.key] = [
      for (final s in e.value.strokes) s.copyWith(id: fresh(s.id)),
    ];
    items[e.key] = [for (final i in e.value.items) i.copyWith(id: fresh(i.id))];
  }
  for (final id in seen) {
    if (id >= next) next = id + 1;
  }
  return (
    ink: StrokeCodec.encodeDocument(pages, next, items: items),
    sides: {
      for (final n in both)
        n: PageSides(
          _pageOf(m, n),
          _pageOf(t, n),
          PageVersion(pages[n]!, items[n]!),
        ),
    },
  );
}

/// [mergeBook], for its result alone.
Uint8List? mergeInk(Uint8List? base, Uint8List? mine, Uint8List? theirs) =>
    mergeBook(base, mine, theirs).ink;

Map<String, dynamic>? _prefs(Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } on FormatException {
    return null;
  }
}

List<int> _marks(Map<String, dynamic>? j) =>
    ((j?['bookmarks'] as List?) ?? const []).cast<int>();

/// Merges the reading state: bookmarks like writing, and the place reached
/// from whichever side read last.
Uint8List? mergePrefs(
  Uint8List? base,
  Uint8List? mine,
  Uint8List? theirs, {
  required bool theirsNewer,
}) {
  final m = _prefs(mine), t = _prefs(theirs);
  if (m == null || t == null) return theirs ?? mine;
  final marks = _mergeList(
    _marks(_prefs(base)),
    _marks(m),
    _marks(t),
    (n) => '$n',
  )..sort();
  return Uint8List.fromList(
    utf8.encode(jsonEncode({...(theirsNewer ? t : m), 'bookmarks': marks})),
  );
}
