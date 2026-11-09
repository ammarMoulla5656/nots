import '../library/library_store.dart';

/// A book of the Masdar app ("المصدر"): its id there, and the volume.
///
/// Masdar shows the same PDF pages, so a page here is the same page there.
/// Its links look like `https://alhikmeh.org/source/<id>/<volume>/<page>/0-1/`.
class MasdarRef {
  const MasdarRef(this.id, this.volume);

  final int id;

  /// 0 for a book without volumes, else the volume number (from 1).
  final int volume;

  static const host = 'alhikmeh.org';

  /// The volume a downloaded part has in Masdar's links. The one place this
  /// rule lives.
  static int volumeOf({required bool multiPart, required int part}) =>
      multiPart ? part : 0;

  /// The link to [page] (a PDF page, from 1) of this book in Masdar.
  Uri pageLink(int page) =>
      Uri.parse('https://$host/source/$id/$volume/${page < 1 ? 1 : page}/0-1/');

  /// How the reader finds a book's Masdar id; set by the home screen, which
  /// holds the catalogue. Null for a book that is not in Masdar.
  static MasdarRef? Function(BookEntry book) resolve = (_) => null;

  @override
  bool operator ==(Object other) =>
      other is MasdarRef && other.id == id && other.volume == volume;

  @override
  int get hashCode => Object.hash(id, volume);
}

/// A page of a book of Masdar, as read from a link.
typedef MasdarPage = ({int id, int volume, int page});

final _link = RegExp(
  r'https?://(?:www\.)?alhikmeh\.org/source/(\d+)/(\d+)/(\d+)',
  caseSensitive: false,
);

/// The first Masdar link in [text] (a link alone, or text shared with a
/// link in it), or null.
MasdarPage? parseMasdarLink(String text) {
  final m = _link.firstMatch(text);
  if (m == null) return null;
  return (
    id: int.parse(m[1]!),
    volume: int.parse(m[2]!),
    page: int.parse(m[3]!),
  );
}
