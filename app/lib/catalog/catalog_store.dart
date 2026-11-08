import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../book/book_text.dart';
import 'catalog_models.dart';

/// Where the library lives on the server. The app only ever reads from here,
/// over plain HTTPS: it holds no server account.
const libraryUrl = 'https://alhikmeh.org/alhawzaapp/publiclibdata/nots/';

/// The categories in the order the Masdar app lists them.
const masdarOrder = [
  'تفسير القرآن',
  'الحديث الشريف',
  'الفقه',
  'أصول الفقه',
  'العقيدة',
  'الرجال',
  'اللغة',
  'البلاغة',
  'المنطق',
  'الأخلاق',
];

/// Where [subject] stands in the Masdar order: its own place when it is one
/// of the categories (or names one, like "كتب الفقه"), else after them all.
int masdarRank(String subject) {
  final exact = masdarOrder.indexOf(subject);
  if (exact >= 0) return exact;
  var best = masdarOrder.length;
  var bestLength = 0;
  for (var i = 0; i < masdarOrder.length; i++) {
    final name = masdarOrder[i];
    if (subject.contains(name) && name.length > bestLength) {
      best = i;
      bestLength = name.length;
    }
  }
  return best;
}

enum CatalogSort { newest, title, author, subject }

/// What the user asked to see. An empty value means "any".
class CatalogQuery {
  const CatalogQuery({
    this.text = '',
    this.subject = '',
    this.language = '',
    this.author = '',
    this.publisher = '',
    this.sort = CatalogSort.newest,
  });

  final String text;
  final String subject;
  final String language;
  final String author;
  final String publisher;
  final CatalogSort sort;

  bool get filtered =>
      subject.isNotEmpty ||
      language.isNotEmpty ||
      author.isNotEmpty ||
      publisher.isNotEmpty;

  CatalogQuery copyWith({
    String? text,
    String? subject,
    String? language,
    String? author,
    String? publisher,
    CatalogSort? sort,
  }) => CatalogQuery(
    text: text ?? this.text,
    subject: subject ?? this.subject,
    language: language ?? this.language,
    author: author ?? this.author,
    publisher: publisher ?? this.publisher,
    sort: sort ?? this.sort,
  );
}

/// The books of [books] that answer [q], in its order. Works on the keys
/// normalised at load time, so it is fast enough to run on every key press.
List<CatalogBook> runQuery(List<CatalogBook> books, CatalogQuery q) {
  final words = normalizeForSearch(q.text).text
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  final out = [
    for (final b in books)
      if ((q.subject.isEmpty || b.subject == q.subject) &&
          (q.language.isEmpty || b.language == q.language) &&
          (q.author.isEmpty || b.author == q.author) &&
          (q.publisher.isEmpty || b.publisher == q.publisher) &&
          words.every(b.searchKey.contains))
        b,
  ];
  switch (q.sort) {
    case CatalogSort.newest:
      out.sort((a, b) => b.added.compareTo(a.added));
    case CatalogSort.title:
      out.sort((a, b) => a.titleKey.compareTo(b.titleKey));
    case CatalogSort.author:
      out.sort((a, b) {
        final c = a.authorKey.compareTo(b.authorKey);
        return c != 0 ? c : a.titleKey.compareTo(b.titleKey);
      });
    case CatalogSort.subject:
      out.sort((a, b) {
        final c = a.subject.compareTo(b.subject);
        return c != 0 ? c : a.titleKey.compareTo(b.titleKey);
      });
  }
  return out;
}

/// The distinct non-empty values of a field, sorted.
List<String> valuesOf(
  List<CatalogBook> books,
  String Function(CatalogBook) field,
) => ({for (final b in books) field(b)}..remove('')).toList()..sort();

/// The catalogue on this device. The names and information of the books are
/// always here: built into the app, then kept up to date from the server, so
/// browsing and searching need no connection and never wait for one.
class CatalogStore extends ChangeNotifier {
  CatalogStore(
    this._root, {
    http.Client? client,
    Future<String> Function()? bundled,
  }) : _client = client ?? http.Client(),
       _bundled =
           bundled ?? (() => rootBundle.loadString('assets/catalog.txt'));

  final Directory _root;
  final http.Client _client;
  final Future<String> Function() _bundled;

  Catalog _catalog = Catalog.empty;
  bool _refreshing = false;
  bool _failed = false;
  String _text = '';

  Catalog get catalog => _catalog;
  List<CatalogBook> get books => _catalog.books;
  bool get refreshing => _refreshing;

  /// The last check of the server failed (usually: no connection).
  bool get failed => _failed;

  File get _cache => File(p.join(_root.path, 'catalog', 'catalog.txt'));

  CatalogBook? byId(String id) {
    for (final b in books) {
      if (b.id == id) return b;
    }
    return null;
  }

  static Uri urlOf(String path) => Uri.parse(libraryUrl).resolve(path);

  /// Shows what the device already has: the last catalogue received, or the
  /// one built into the app.
  Future<void> load() async {
    for (final read in [
      () async => await _cache.exists() ? _cache.readAsString() : null,
      () async => _bundled(),
    ]) {
      try {
        final text = await read();
        if (text == null) continue;
        _catalog = await compute(Catalog.parse, text);
        _text = text;
        notifyListeners();
        return;
      } on FormatException {
        continue; // a damaged copy: try the next one
      }
    }
  }

  /// Gets the current catalogue from the server. Failing leaves the catalogue
  /// as it is.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    _failed = false;
    notifyListeners();
    try {
      final r = await _client
          .get(urlOf('catalog.txt'))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) throw HttpException('${r.statusCode}');
      final text = utf8.decode(r.bodyBytes);
      if (text != _text) {
        _catalog = await compute(Catalog.parse, text);
        _text = text;
        await _cache.parent.create(recursive: true);
        final tmp = File('${_cache.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(_cache.path);
      }
    } on Exception {
      _failed = true;
    }
    _refreshing = false;
    notifyListeners();
  }
}
