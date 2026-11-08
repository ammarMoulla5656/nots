/// Pages the user added inside a book: blank sheets for notes, each placed
/// after a page of the book. The book's file never changes; the reader shows
/// the book's pages and these together.
///
/// Writing on an added page is kept with the book's writing under the page
/// key [extraBase] + its id, so it travels (and syncs) with the book, and
/// the book's own pages keep their numbers whatever is added between them.
library;

const extraBase = 1000000;

/// One added page: its [id] and the book page it follows (0: before the
/// first page).
class ExtraPage {
  const ExtraPage(this.id, this.after, [this.paper = '']);

  final int id;
  final int after;

  /// Its paper (see `Paper` in paper_templates.dart); empty: plain white.
  final String paper;

  int get key => extraBase + id;

  List<Object> toJson() => [id, after, if (paper.isNotEmpty) paper];

  static ExtraPage? fromJson(Object? j) {
    if (j is! List || j.length < 2) return null;
    final (id, after) = (j[0], j[1]);
    if (id is! num || after is! num) return null;
    final paper = j.length > 2 && j[2] is String ? j[2] as String : '';
    return ExtraPage(id.toInt(), after.toInt(), paper);
  }
}

bool isExtraKey(int key) => key >= extraBase;

/// Where each page of the reader comes from. A "place" is a page's number
/// in the reader (1 = first shown); a "key" is the book's own page number,
/// or [ExtraPage.key] for an added page. With no added pages both are the
/// same.
class PageMap {
  PageMap._(this._keys, this.bookPages)
    : _places = {for (var i = 0; i < _keys.length; i++) _keys[i]: i + 1};

  /// No added pages: places and keys are the same.
  static final none = PageMap._(const [], 0);

  /// [extras] in the order the user placed them.
  factory PageMap.build(int bookPages, List<ExtraPage> extras) {
    final keys = <int>[];
    for (var after = 0; after <= bookPages; after++) {
      if (after > 0) keys.add(after);
      for (final e in extras) {
        final at = e.after.clamp(0, bookPages);
        if (at == after) keys.add(e.key);
      }
    }
    return PageMap._(keys, bookPages);
  }

  final List<int> _keys;
  final Map<int, int> _places;

  /// Pages of the book itself (0 when there are no added pages).
  final int bookPages;

  bool get isNone => _keys.isEmpty;

  /// Keys in reading order.
  List<int> get keys => List.unmodifiable(_keys);

  int keyOf(int place) {
    if (_keys.isEmpty) return place;
    return _keys[(place - 1).clamp(0, _keys.length - 1)];
  }

  int placeOf(int key) {
    if (_keys.isEmpty) return key;
    return _places[key] ?? (isExtraKey(key) ? 1 : key.clamp(1, _keys.length));
  }

  /// The book page shown at [place], or the one an added page follows.
  int bookPageAt(int place) {
    if (_keys.isEmpty) return place;
    for (var i = (place - 1).clamp(0, _keys.length - 1); i >= 0; i--) {
      if (!isExtraKey(_keys[i])) return _keys[i];
    }
    return 0;
  }
}
