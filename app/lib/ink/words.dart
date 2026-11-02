import 'dart:math' as math;
import 'dart:ui';

/// One word of a PDF page's text layer, with its box in PDF points
/// (top-left origin, like the ink).
class WordBox {
  const WordBox(this.start, this.end, this.text, this.rect, [this.id = -1]);

  /// Character range in the page text.
  final int start;
  final int end;
  final String text;
  final Rect rect;

  /// Index of the word in the whole book text (from the book's word map),
  /// or -1 for a word read from the PDF alone.
  final int id;
}

bool _isSpace(int cu) =>
    cu == 0x20 ||
    cu == 0x09 ||
    cu == 0x0A ||
    cu == 0x0D ||
    cu == 0xA0 ||
    cu == 0x200E ||
    cu == 0x200F;

/// True when [a] and [b] sit on the same text line: their vertical extents
/// overlap by at least half of the smaller one.
bool sameLine(Rect a, Rect b) {
  final overlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  return overlap >= 0.5 * math.min(a.height, b.height);
}

/// Splits page text into words. [rects] holds one box per character of
/// [text] (null or empty for characters without a box). A word ends at
/// white space, or where the next character is on another line.
List<WordBox> splitWords(String text, List<Rect?> rects) {
  final words = <WordBox>[];
  final n = math.min(text.length, rects.length);
  var i = 0;
  while (i < n) {
    if (_isSpace(text.codeUnitAt(i))) {
      i++;
      continue;
    }
    final start = i;
    Rect? box;
    while (i < n && !_isSpace(text.codeUnitAt(i))) {
      final r = rects[i];
      if (r != null && !r.isEmpty) {
        if (box != null && !sameLine(box, r)) break;
        box = box == null ? r : box.expandToInclude(r);
      }
      i++;
    }
    if (box != null) {
      words.add(WordBox(start, i, text.substring(start, i), box));
    }
  }
  return words;
}

/// Index of the word under [p] (PDF points), or null. [tolerance] widens
/// the boxes a little so a finger can hit short words.
int? wordAt(List<WordBox> words, Offset p, {double tolerance = 2}) {
  int? best;
  var bestDist = double.infinity;
  for (var i = 0; i < words.length; i++) {
    final r = words[i].rect.inflate(tolerance);
    if (!r.contains(p)) continue;
    final d = (r.center - p).distanceSquared;
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return best;
}

/// One rectangle per text line covered by [words] (in reading order).
List<Rect> lineRects(List<WordBox> words) {
  final lines = <Rect>[];
  for (final w in words) {
    if (lines.isNotEmpty && sameLine(lines.last, w.rect)) {
      lines[lines.length - 1] = lines.last.expandToInclude(w.rect);
    } else {
      lines.add(w.rect);
    }
  }
  return lines;
}

/// Indices of the words a stroke passed over, in reading order. [path] is the
/// stroke's polyline (PDF points); each segment is sampled every [step]
/// points, and a word counts when a sample falls inside its box widened by
/// [tolerance]. A stroke that touches no word returns an empty list.
List<int> wordsAlongPath(
  List<WordBox> words,
  List<Offset> path, {
  double tolerance = 1.5,
  double step = 1.5,
}) {
  if (path.isEmpty || words.isEmpty) return const [];
  final hit = <int>{};
  void sample(Offset p) {
    for (var i = 0; i < words.length; i++) {
      if (!hit.contains(i) && words[i].rect.inflate(tolerance).contains(p)) {
        hit.add(i);
      }
    }
  }

  sample(path.first);
  for (var i = 1; i < path.length; i++) {
    final a = path[i - 1], b = path[i];
    final n = math.max(1, ((b - a).distance / step).ceil());
    for (var k = 1; k <= n; k++) {
      sample(Offset.lerp(a, b, k / n)!);
    }
  }
  return hit.toList()..sort();
}
