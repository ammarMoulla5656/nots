import 'dart:math' as math;
import 'dart:ui';

import 'ink_document.dart';
import 'note_items.dart';
import 'words.dart';

/// The share (0..1) of the area of [rects] that [others] cover.
double rectCoverage(List<Rect> rects, List<Rect> others) {
  var total = 0.0, covered = 0.0;
  for (final r in rects) {
    total += r.width * r.height;
    var best = 0.0;
    for (final o in others) {
      final i = r.intersect(o);
      if (i.width > 0 && i.height > 0) {
        best = math.max(best, i.width * i.height);
      }
    }
    covered += best;
  }
  return total <= 0 ? 0 : covered / total;
}

/// [item] shrunk to [rects].
NoteItem _cutTo(NoteItem item, List<Rect> rects) {
  var box = rects.first;
  for (final r in rects.skip(1)) {
    box = box.expandToInclude(r);
  }
  return item.copyWith(
    rects: rects,
    x: box.left,
    y: box.top,
    w: box.width,
    h: box.height,
  );
}

/// Puts [mark] on [page]. Words that already have this mark in the same
/// colour lose it instead; in another colour the new one replaces it. Either
/// way those words leave the old marks, which keep their other words: two
/// colours on the same letters would mix.
void applyMark(InkDocument doc, int page, NoteItem mark) {
  final same = [
    for (final it in doc.itemsOf(page))
      if (it.kind == ItemKind.mark &&
          it.style == mark.style &&
          rectCoverage(mark.rects, it.rects) > 0)
        it,
  ];
  final covered = rectCoverage(mark.rects, [
    for (final it in same) ...it.rects,
  ]);
  final takeOff = covered > 0.5 && same.every((it) => it.color == mark.color);
  var placed = takeOff;
  for (final it in same) {
    final rest = rectsMinus(it.rects, mark.rects);
    if (rest.isNotEmpty) {
      doc.replaceItem(page, _cutTo(it, rest));
    } else if (!placed) {
      doc.replaceItem(page, mark.copyWith(id: it.id));
      placed = true;
    } else {
      doc.removeItem(page, it.id);
    }
  }
  if (!placed) doc.addItem(page, mark);
}
