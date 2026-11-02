import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';

/// A heading of the linked book text: a table-of-contents entry.
class BookHeading {
  const BookHeading(this.title, this.level, this.page);

  final String title;

  /// 1 for main headings, 2 for sub-headings, ...
  final int level;

  /// 1-based page number in the book text (equal to the PDF page when the
  /// text matches the printed edition page by page).
  final int page;

  Map<String, Object> toJson() => {'t': title, 'l': level, 'p': page};

  static BookHeading fromJson(Map<String, dynamic> j) =>
      BookHeading(j['t'] as String, j['l'] as int, j['p'] as int);
}

/// Text normalised for searching, with a map back to the original text.
class NormalizedText {
  NormalizedText(this.text, this.origIndex);

  final String text;

  /// For each character of [text], its index in the original string.
  final List<int> origIndex;
}

bool _isDiacritic(int c) =>
    (c >= 0x064B && c <= 0x065F) || // harakat, shadda, sukun, ...
    (c >= 0x0610 && c <= 0x061A) ||
    c == 0x0670 || // superscript alef
    (c >= 0x06D6 && c <= 0x06ED) || // Quranic marks
    c == 0x0640; // tatweel

int _fold(int c) {
  switch (c) {
    case 0x0622: // آ
    case 0x0623: // أ
    case 0x0625: // إ
    case 0x0671: // ٱ
      return 0x0627; // ا
    case 0x0649: // ى
    case 0x064A: // ي
    case 0x06CC: // Persian ye
      return 0x064A;
    case 0x0629: // ة
      return 0x0647; // ه
    case 0x0624: // ؤ
      return 0x0648; // و
    case 0x0626: // ئ
      return 0x064A; // ي
    case 0x06A9: // Persian kaf
      return 0x0643;
  }
  if (c >= 0x0660 && c <= 0x0669) return 0x30 + c - 0x0660; // Arabic digits
  if (c >= 0x06F0 && c <= 0x06F9) return 0x30 + c - 0x06F0; // Persian digits
  if (c >= 0x41 && c <= 0x5A) return c + 32; // Latin lower case
  return c;
}

bool _isSpace(int c) =>
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0xA0;

/// Removes diacritics and tatweel, unifies alef/ya/ta-marbuta/hamza seats and
/// digits, and collapses white space, so a search finds the word whatever
/// way it is written. Keeps a map back to the original characters.
NormalizedText normalizeForSearch(String s) {
  final out = StringBuffer();
  final map = <int>[];
  var lastSpace = true;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (_isDiacritic(c)) continue;
    if (_isSpace(c)) {
      if (lastSpace) continue;
      out.writeCharCode(0x20);
      map.add(i);
      lastSpace = true;
      continue;
    }
    out.writeCharCode(_fold(c));
    map.add(i);
    lastSpace = false;
  }
  return NormalizedText(out.toString(), map);
}

/// One place where a search matched.
class SearchHit {
  const SearchHit(this.page, this.start, this.end);

  /// 1-based page.
  final int page;

  /// Match range in the original page text.
  final int start;
  final int end;
}

/// Where the words of one page's text sit on the PDF page: from the word
/// map that nots-cook embeds in the PDF.
class PageLayout {
  PageLayout._(this.kind, this.firstWord, this.starts, this.ends, this.boxes);

  /// "text", "ocr", "image" (a picture: words without places) or "blank".
  final String kind;

  /// Index in the whole book of this page's first word.
  final int firstWord;

  /// Character range of each word in the page text.
  final Int32List starts;
  final Int32List ends;

  /// left, top, right, bottom of each word in PDF points (top-left origin);
  /// NaN for a word whose place is unknown.
  final Float32List boxes;

  int get length => starts.length;

  Rect? rectOf(int i) {
    final l = boxes[4 * i];
    if (l.isNaN) return null;
    return Rect.fromLTRB(
      l,
      boxes[4 * i + 1],
      boxes[4 * i + 2],
      boxes[4 * i + 3],
    );
  }

  /// Words of [text] (separated by spaces and line breaks) with the boxes of
  /// a word map page: per word four tenths-of-a-point differences from the
  /// previous placed word, or null alone for a word without a place.
  static PageLayout parse(
    String kind,
    int firstWord,
    String text,
    List? deltas,
  ) {
    final starts = <int>[], ends = <int>[];
    var i = 0;
    while (i < text.length) {
      final c = text.codeUnitAt(i);
      if (c == 0x20 || c == 0x0A) {
        i++;
        continue;
      }
      final s = i;
      while (i < text.length) {
        final d = text.codeUnitAt(i);
        if (d == 0x20 || d == 0x0A) break;
        i++;
      }
      starts.add(s);
      ends.add(i);
    }
    final n = starts.length;
    final boxes = Float32List(4 * n)..fillRange(0, 4 * n, double.nan);
    if (deltas != null) {
      var k = 0, w = 0;
      final prev = [0, 0, 0, 0];
      while (k < deltas.length && w < n) {
        final v = deltas[k];
        if (v == null) {
          k++;
          w++;
          continue;
        }
        if (k + 4 > deltas.length) break;
        for (var j = 0; j < 4; j++) {
          prev[j] += (deltas[k + j] as num).toInt();
          boxes[4 * w + j] = prev[j] / 10;
        }
        k += 4;
        w++;
      }
      if (w != n || k != deltas.length) {
        // A map that does not fit its text: no places rather than wrong ones.
        boxes.fillRange(0, 4 * n, double.nan);
      }
    }
    return PageLayout._(
      kind,
      firstWord,
      Int32List.fromList(starts),
      Int32List.fromList(ends),
      boxes,
    );
  }

  /// Index of the first word ending after [offset] (binary search).
  int _wordAtOrAfter(int offset) {
    var lo = 0, hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ends[mid] <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Words overlapping the character range [start, end), as (first, last)
  /// page word indices, or null.
  (int, int)? wordsIn(int start, int end) {
    final a = _wordAtOrAfter(start);
    if (a >= length || starts[a] >= end) return null;
    var b = a;
    while (b + 1 < length && starts[b + 1] < end) {
      b++;
    }
    return (a, b);
  }

  /// Words covered by [rects] (PDF points, top-left origin), in reading
  /// order: at least [share] of a word's box inside one of them, so a
  /// selection that starts or ends inside a word still takes the word.
  List<int> wordsInRects(
    List<Rect> rects, {
    double slack = 1,
    double share = 0.3,
  }) {
    final out = <int>[];
    final inflated = [for (final r in rects) r.inflate(slack)];
    for (var i = 0; i < length; i++) {
      final r = rectOf(i);
      if (r == null) continue;
      final area = r.width * r.height;
      for (final x in inflated) {
        final o = r.intersect(x);
        if (o.width > 0 && o.height > 0 && o.width * o.height >= share * area) {
          out.add(i);
          break;
        }
      }
    }
    return out;
  }

  /// The exact text of page words [ids] (reading order): the source's own
  /// space or line break between neighbours, one space across gaps.
  String textOf(String pageText, List<int> ids) {
    final b = StringBuffer();
    for (var k = 0; k < ids.length; k++) {
      final i = ids[k];
      if (k > 0) {
        final prev = ids[k - 1];
        b.write(
          i == prev + 1 ? pageText.substring(ends[prev], starts[i]) : ' ',
        );
      }
      b.write(pageText.substring(starts[i], ends[i]));
    }
    return b.toString();
  }
}

/// The clean text of a book, page by page, with its headings: from the word
/// map embedded in the PDF (with every word's place), or from a Word file
/// linked by hand that matches the PDF page for page.
class BookText {
  BookText({
    required this.pages,
    required this.headings,
    this.source = '',
    this.pageOffset = 0,
    this.layout,
    this.sourceId = '',
    this.title = '',
  }) : _norm = [for (final p in pages) normalizeForSearch(p)];

  /// Text of each page; pages[0] is page 1.
  final List<String> pages;
  final List<BookHeading> headings;

  /// File name the text came from.
  final String source;

  /// PDF page = book page + [pageOffset] (0 when they match exactly).
  final int pageOffset;

  /// Every word's place on its page, when the text came from a word map.
  final List<PageLayout>? layout;

  /// Book id (content fingerprint) of the PDF the word map was made from:
  /// writing done on that edition fits this one exactly.
  final String sourceId;

  /// Title written in the word map.
  final String title;

  final List<NormalizedText> _norm;

  int get pageCount => pages.length;

  /// True when the text is the PDF's own word map (not a separate file).
  bool get embedded => layout != null;

  /// Layout of book page [bookPage], or null.
  PageLayout? layoutOf(int bookPage) {
    final l = layout;
    if (l == null || bookPage < 1 || bookPage > l.length) return null;
    return l[bookPage - 1];
  }

  /// Boxes of the words a hit covers (PDF points, top-left origin).
  List<Rect> hitRects(SearchHit h) {
    final l = layoutOf(h.page);
    final range = l?.wordsIn(h.start, h.end);
    if (l == null || range == null) return const [];
    return [for (var i = range.$1; i <= range.$2; i++) ?l.rectOf(i)];
  }

  /// The exact text of page words [from]..[to] (inclusive), with the line
  /// breaks between paragraphs.
  String textOfWords(int bookPage, int from, int to) {
    final l = layoutOf(bookPage)!;
    return pages[bookPage - 1].substring(l.starts[from], l.ends[to]);
  }

  int pdfPageOf(int bookPage) => bookPage + pageOffset;
  int bookPageOf(int pdfPage) => pdfPage - pageOffset;

  /// The heading whose section contains [bookPage], or null before the first.
  BookHeading? sectionOf(int bookPage) {
    BookHeading? found;
    for (final h in headings) {
      if (h.page > bookPage) break;
      found = h;
    }
    return found;
  }

  /// All matches of [query] in reading order (at most [limit]).
  List<SearchHit> search(String query, {int limit = 2000}) {
    final q = normalizeForSearch(query).text.trim();
    if (q.isEmpty) return const [];
    final hits = <SearchHit>[];
    for (var p = 0; p < _norm.length; p++) {
      final n = _norm[p];
      var i = n.text.indexOf(q);
      while (i >= 0) {
        hits.add(
          SearchHit(p + 1, n.origIndex[i], n.origIndex[i + q.length - 1] + 1),
        );
        if (hits.length >= limit) return hits;
        i = n.text.indexOf(q, i + q.length);
      }
    }
    return hits;
  }

  /// Text around a hit: (before, match, after), on one line.
  ({String before, String match, String after}) snippet(
    SearchHit h, {
    int context = 45,
  }) {
    final t = pages[h.page - 1];
    String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
    final from = (h.start - context).clamp(0, t.length);
    final to = (h.end + context).clamp(0, t.length);
    return (
      before: (from > 0 ? '…' : '') + clean(t.substring(from, h.start)),
      match: clean(t.substring(h.start, h.end)),
      after: clean(t.substring(h.end, to)) + (to < t.length ? '…' : ''),
    );
  }

  String toJson() => jsonEncode({
    'v': 1,
    'source': source,
    'offset': pageOffset,
    'pages': pages,
    'headings': [for (final h in headings) h.toJson()],
  });

  /// The book text of a word map (see tools/cook/FORMAT.md).
  static BookText fromWordMap(Map<String, dynamic> j) {
    if (j['format'] != 'nots-words') {
      throw const FormatException('ليست خريطة كلمات');
    }
    final pages = <String>[];
    final layout = <PageLayout>[];
    var first = 0;
    for (final p in (j['pages'] as List).cast<Map<String, dynamic>>()) {
      final text = p['t'] as String? ?? '';
      final l = PageLayout.parse(
        p['k'] as String? ?? 'text',
        first,
        text,
        p['b'] as List?,
      );
      pages.add(text);
      layout.add(l);
      first += l.length;
    }
    final src = j['source'] as Map<String, dynamic>? ?? const {};
    return BookText(
      pages: pages,
      headings: [
        for (final h
            in (j['headings'] as List? ?? const [])
                .cast<Map<String, dynamic>>())
          BookHeading(h['t'] as String, h['l'] as int, h['p'] as int),
      ],
      source: src['text'] as String? ?? 'nots-words',
      layout: layout,
      sourceId: src['pdfId'] as String? ?? '',
      title: j['title'] as String? ?? '',
    );
  }

  /// Text saved by [toJson], or a word map.
  static BookText fromJson(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    if (j['format'] == 'nots-words') return fromWordMap(j);
    return BookText(
      pages: (j['pages'] as List).cast<String>(),
      headings: [
        for (final h in (j['headings'] as List))
          BookHeading.fromJson(h as Map<String, dynamic>),
      ],
      source: j['source'] as String? ?? '',
      pageOffset: j['offset'] as int? ?? 0,
    );
  }
}

String _xmlUnescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'),
    (m) {
      final e = m.group(1)!;
      switch (e) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      final code = e.startsWith('#x')
          ? int.parse(e.substring(2), radix: 16)
          : int.parse(e.substring(1));
      return String.fromCharCode(code);
    },
  );
}

/// Heading level per paragraph style id, read from styles.xml: styles named
/// "heading N" (any language's style id) and the built-in "HeadingN" ids.
Map<String, int> _headingStyles(String? stylesXml) {
  final levels = <String, int>{};
  if (stylesXml != null) {
    final style = RegExp(
      r'<w:style\b[^>]*w:styleId="([^"]+)"[^>]*>(.*?)</w:style>',
      dotAll: true,
    );
    for (final m in style.allMatches(stylesXml)) {
      final name = RegExp(r'<w:name w:val="([^"]+)"')
          .firstMatch(m.group(2)!)
          ?.group(1);
      final lvl = RegExp(
        r'^heading (\d)$',
        caseSensitive: false,
      ).firstMatch(name ?? '')?.group(1);
      if (lvl != null) levels[m.group(1)!] = int.parse(lvl);
    }
  }
  return levels;
}

final _para = RegExp(r'<w:p\b[^>]*?(?:/>|>(.*?)</w:p>)', dotAll: true);
final _token = RegExp(
  r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>' // text
  r'|<w:tab/>' // tab
  r'|<w:br\b([^>]*)/>' // line or page break
  r'|<w:pageBreakBefore(?:\s+w:val="(?:true|1|on)")?\s*/>' // break before
  r'|<w:pStyle w:val="([^"]+)"\s*/>' // paragraph style
  r'|<w:outlineLvl w:val="(\d)"\s*/>', // direct outline level
);

/// Reads a Word (.docx) file: one page per explicit page break, headings from
/// heading styles (or outline levels).
BookText parseDocx(Uint8List bytes, {String source = ''}) {
  final zip = ZipDecoder().decodeBytes(bytes);
  final doc = zip.findFile('word/document.xml');
  if (doc == null) {
    throw const FormatException('ليس ملف Word صالحاً (لا يوجد document.xml)');
  }
  final xml = utf8.decode(doc.content, allowMalformed: true);
  final stylesFile = zip.findFile('word/styles.xml');
  final headingStyles = _headingStyles(
    stylesFile == null
        ? null
        : utf8.decode(stylesFile.content, allowMalformed: true),
  );

  final pages = <StringBuffer>[StringBuffer()];
  final headings = <BookHeading>[];

  for (final pm in _para.allMatches(xml)) {
    final body = pm.group(1) ?? '';
    final text = StringBuffer();
    int? level;
    int? textPage;
    for (final t in _token.allMatches(body)) {
      final s = t.group(0)!;
      if (t.group(1) != null) {
        final piece = _xmlUnescape(t.group(1)!);
        if (piece.isNotEmpty) {
          textPage ??= pages.length;
          text.write(piece);
          pages.last.write(piece);
        }
      } else if (s == '<w:tab/>') {
        text.write(' ');
        pages.last.write(' ');
      } else if (s.startsWith('<w:br')) {
        if ((t.group(2) ?? '').contains('w:type="page"')) {
          pages.add(StringBuffer());
        } else {
          text.write(' ');
          pages.last.write('\n');
        }
      } else if (s.startsWith('<w:pageBreakBefore')) {
        if (pages.last.isNotEmpty) pages.add(StringBuffer());
      } else if (t.group(3) != null) {
        level ??=
            headingStyles[t.group(3)!] ??
            int.tryParse(
              RegExp(r'^Heading(\d)$').firstMatch(t.group(3)!)?.group(1) ?? '',
            );
      } else if (t.group(4) != null) {
        level ??= int.parse(t.group(4)!) + 1;
      }
    }
    pages.last.write('\n');
    final title = text.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (level != null && level <= 6 && title.isNotEmpty) {
      headings.add(BookHeading(title, level, textPage ?? pages.length));
    }
  }

  return BookText(
    pages: [for (final p in pages) p.toString().trim()],
    headings: headings,
    source: source,
  );
}
