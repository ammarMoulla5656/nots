import 'dart:convert';

import '../book/book_text.dart';

/// What a published file allows. The publisher finds this when uploading
/// (tools/publisher), so the reader knows before downloading.
class BookFeatures {
  const BookFeatures({
    this.search = false,
    this.marks = false,
    this.copy = false,
    this.toc = false,
    this.exact = false,
  });

  final bool search;
  final bool marks;
  final bool copy;
  final bool toc;

  /// Corrected text with every word's place (a nots-cook word map).
  final bool exact;

  static BookFeatures fromJson(Map<String, dynamic>? j) => BookFeatures(
    search: j?['search'] == true,
    marks: j?['marks'] == true,
    copy: j?['copy'] == true,
    toc: j?['toc'] == true,
    exact: j?['exact'] == true,
  );

  /// Each feature with its name, for showing what is and is not supported.
  /// Writing with the pen works on every book.
  List<(String, bool)> get labelled => [
    ('الكتابة بالقلم', true),
    ('بحث', search),
    ('تعليم الكلمات', marks),
    ('نسخ النص', copy),
    ('فهرس', toc),
    ('نص مصحَّح', exact),
  ];
}

/// One downloadable file of a book: the whole book, or one of its parts.
class CatalogPart {
  const CatalogPart({
    required this.number,
    required this.label,
    required this.format,
    required this.file,
    required this.size,
    required this.sha256,
    required this.pages,
    required this.features,
  });

  final int number;
  final String label;

  /// "pdf" or "nots".
  final String format;

  /// Path under the library's folder on the server.
  final String file;
  final int size;
  final String sha256;
  final int pages;
  final BookFeatures features;

  String get formatName => format == 'nots' ? 'نوتس' : 'PDF';

  static CatalogPart fromJson(Map<String, dynamic> j) => CatalogPart(
    number: (j['n'] as num).toInt(),
    label: j['label'] as String? ?? '',
    format: j['format'] as String? ?? 'pdf',
    file: j['file'] as String,
    size: (j['size'] as num?)?.toInt() ?? 0,
    sha256: j['sha256'] as String? ?? '',
    pages: (j['pages'] as num?)?.toInt() ?? 0,
    features: BookFeatures.fromJson(j['features'] as Map<String, dynamic>?),
  );
}

/// A book of the library on the server. Only this information comes with the
/// catalogue; the files come when downloaded.
class CatalogBook {
  CatalogBook({
    required this.id,
    required this.title,
    required this.author,
    required this.investigator,
    required this.edition,
    required this.partsCount,
    required this.language,
    required this.subject,
    required this.publisher,
    required this.added,
    required this.cover,
    required this.parts,
    this.masdarId,
  }) : searchKey = normalizeForSearch(
         '$title $author $investigator $publisher $subject',
       ).text,
       titleKey = normalizeForSearch(title).text,
       authorKey = normalizeForSearch(author).text;

  final String id;
  final String title;
  final String author;
  final String investigator;
  final String edition;

  /// Parts the book has in all; [parts] may list fewer while the rest are
  /// not uploaded yet.
  final int partsCount;
  final String language;
  final String subject;
  final String publisher;
  final String added;
  final String cover;
  final List<CatalogPart> parts;

  /// The book's id in the Masdar app, when it is there: its logo shows in
  /// the reader and opens the same page there. Null when it is not.
  final int? masdarId;

  /// Normalised once here, so typing in the search box stays instant.
  final String searchKey;
  final String titleKey;
  final String authorKey;

  bool get multiPart => partsCount > 1 || parts.length > 1;
  int get totalSize => parts.fold(0, (n, p) => n + p.size);

  CatalogPart? partNumbered(int n) {
    for (final p in parts) {
      if (p.number == n) return p;
    }
    return null;
  }

  /// The title a downloaded part goes by in the user's library.
  String titleOf(CatalogPart p) {
    if (!multiPart) return title;
    return '$title - ${p.label.isEmpty ? 'الجزء ${p.number}' : p.label}';
  }

  static CatalogBook fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] as String? ?? '').trim();
    final parts = [
      for (final p in (j['parts'] as List? ?? const []))
        CatalogPart.fromJson(p as Map<String, dynamic>),
    ]..sort((a, b) => a.number.compareTo(b.number));
    return CatalogBook(
      id: j['id'] as String,
      title: s('title'),
      author: s('author'),
      investigator: s('investigator'),
      edition: s('edition'),
      partsCount: (j['parts_count'] as num?)?.toInt() ?? parts.length,
      language: s('language'),
      subject: s('subject'),
      publisher: s('publisher'),
      added: s('added'),
      cover: s('cover'),
      parts: parts,
      masdarId: switch (j['masdar']) {
        final num n when n > 0 => n.toInt(),
        final String t when (int.tryParse(t.trim()) ?? 0) > 0 => int.parse(
          t.trim(),
        ),
        _ => null,
      },
    );
  }
}

/// The whole catalogue.
class Catalog {
  const Catalog(this.updated, this.books);

  static const empty = Catalog('', []);

  final String updated;
  final List<CatalogBook> books;

  /// Reads the catalogue text. A single damaged book is skipped; anything
  /// that is not a catalogue at all is a [FormatException].
  static Catalog parse(String text) {
    final j = jsonDecode(text);
    if (j is! Map<String, dynamic> || j['format'] != 'nots-catalog') {
      throw const FormatException('ليس فهرس نوتس');
    }
    final books = <CatalogBook>[];
    for (final b in j['books'] as List? ?? const []) {
      try {
        books.add(CatalogBook.fromJson(b as Map<String, dynamic>));
      } on TypeError {
        continue;
      }
    }
    return Catalog(j['updated'] as String? ?? '', books);
  }
}
