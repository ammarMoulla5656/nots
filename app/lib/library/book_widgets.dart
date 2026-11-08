import 'package:flutter/material.dart';

import '../catalog/book_cover.dart';
import '../reader/reader_prefs.dart';
import '../ui/theme.dart';
import 'library_store.dart';

/// How far each book has been read, kept up to date for lists of books.
/// The share is read from the reader's own saved state: the page last read
/// over the number of pages (known once the book was opened).
class ReadProgress extends ChangeNotifier {
  final _shares = <String, ({int page, int count})>{};

  /// 0..1, or null when the book was never opened or its size is unknown.
  double? shareOf(String id) {
    final p = _shares[id];
    if (p == null || p.count <= 0) return null;
    return (p.page / p.count).clamp(0.0, 1.0);
  }

  ({int page, int count})? of(String id) => _shares[id];

  Future<void> load(Iterable<String> ids) async {
    var changed = false;
    for (final id in ids) {
      final p = await ReaderPrefs.peekProgress(id);
      if (p == null) continue;
      final old = _shares[id];
      if (old == null || old.page != p.page || old.count != p.count) {
        _shares[id] = p;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }
}

/// A book of the library in a grid: its cover with the reading bar, the
/// title and a line under it, and a button for more.
class BookGridItem extends StatelessWidget {
  const BookGridItem({
    super.key,
    required this.book,
    required this.subtitle,
    required this.onTap,
    required this.onMore,
    this.progress,
    this.inAccountOnly = false,
    this.title,
    this.volumes = 1,
  });

  final BookEntry book;

  /// Shown in place of the book's own title (a book of several volumes).
  final String? title;

  /// Volumes standing under this one cover: more than one shows as a pile.
  final int volumes;
  final String subtitle;
  final double? progress;

  /// The file is not on this device yet: a cloud badge says so.
  final bool inAccountOnly;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BookCover(
                  book.cover,
                  ownId: book.id,
                  width: box.maxWidth,
                  progress: progress,
                  badge: inAccountOnly
                      ? Icons.cloud_outlined
                      : volumes > 1
                      ? Icons.layers_outlined
                      : null,
                ),
                const SizedBox(height: 9),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 22),
                  child: Text(
                    title ?? book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 22),
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Brand.muted),
                  ),
                ),
              ],
            ),
          ),
          PositionedDirectional(
            end: -6,
            bottom: 0,
            child: SizedBox(
              width: 30,
              height: 34,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: 'خيارات',
                icon: Icon(Icons.more_horiz, size: 18, color: Brand.muted),
                onPressed: onMore,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Grid of covers sized to the room: at least three to a row.
class CoverGridSliver extends StatelessWidget {
  const CoverGridSliver({
    super.key,
    required this.count,
    required this.itemBuilder,
    this.textHeight = 56,
  });

  final int count;
  final Widget Function(BuildContext, int) itemBuilder;
  final double textHeight;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, c) {
        final w = c.crossAxisExtent;
        final cols = (w / 130).floor().clamp(3, 12);
        const gap = 12.0;
        final cell = (w - gap * (cols - 1)) / cols;
        return SliverGrid(
          delegate: SliverChildBuilderDelegate(itemBuilder, childCount: count),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: gap,
            mainAxisSpacing: 20,
            mainAxisExtent: cell / BookCover.ratio + textHeight,
          ),
        );
      },
    );
  }
}

/// A search box in a pale frame, with a clear button.
class SearchBox extends StatelessWidget {
  const SearchBox({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
  });

  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Brand.muted, fontSize: 14.5),
          prefixIcon: Icon(Icons.search, size: 20, color: Brand.muted),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
