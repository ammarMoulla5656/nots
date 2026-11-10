import 'package:flutter/material.dart';

import '../book/book_text.dart' show normalizeForSearch;
import '../library/book_widgets.dart' show CoverGridSliver, SearchBox;
import '../library/library_store.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_cover.dart';
import 'book_detail_screen.dart';
import 'catalog_models.dart';
import 'catalog_store.dart';
import 'download_manager.dart';

/// The books of the library by [author], as in «الكتب»: a tick on the ones
/// already downloaded; a tap opens the book's page.
class AuthorScreen extends StatefulWidget {
  const AuthorScreen({
    super.key,
    required this.author,
    required this.store,
    required this.downloads,
    required this.library,
    required this.onOpen,
  });

  final String author;
  final CatalogStore store;
  final DownloadManager downloads;
  final LibraryStore library;
  final void Function(BookEntry) onOpen;

  /// The same author, written with or without diacritics or hamza.
  static bool sameAuthor(String a, String b) {
    final x = normalizeForSearch(a).text.trim();
    return x.isNotEmpty && x == normalizeForSearch(b).text.trim();
  }

  static Future<void> open(
    BuildContext context, {
    required String author,
    required CatalogStore store,
    required DownloadManager downloads,
    required LibraryStore library,
    required void Function(BookEntry) onOpen,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AuthorScreen(
        author: author,
        store: store,
        downloads: downloads,
        library: library,
        onOpen: onOpen,
      ),
    ),
  );

  @override
  State<AuthorScreen> createState() => _AuthorScreenState();
}

class _AuthorScreenState extends State<AuthorScreen> {
  /// The category shown; 'الكل' shows every category, each under its title.
  String _category = 'الكل';

  /// What is typed in the search: a part of a title.
  String _query = '';

  bool _owned(CatalogBook b) => b.parts.any(
    (p) => widget.library.installedCatalog(b.id, p.number) != null,
  );

  void _details(CatalogBook b) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BookDetailScreen(
        book: b,
        downloads: widget.downloads,
        library: widget.library,
        onOpen: widget.onOpen,
        store: widget.store,
      ),
    ),
  );

  Widget _book(CatalogBook b) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _details(b),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BookCover(b.cover, badge: _owned(b) ? Icons.check : null),
        const SizedBox(height: 9),
        Text(
          b.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1.45,
          ),
        ),
        Text(
          b.subject,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: Brand.muted),
        ),
      ],
    ),
  );

  /// The title of a category, as on the shelves of «الكتب».
  Widget _shelfTitle(String name) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 22, 0, 12),
    child: Row(
      children: [
        Transform.rotate(
          angle: 0.785398,
          child: Container(width: 9, height: 9, color: Brand.gold),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            name,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final side = sidePadding(context);
    return Scaffold(
      backgroundColor: Brand.paper,
      appBar: AppBar(title: Text(widget.author)),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          widget.store,
          widget.library,
          widget.downloads,
        ]),
        builder: (context, _) {
          final all = [
            for (final b in widget.store.books)
              if (AuthorScreen.sameAuthor(b.author, widget.author)) b,
          ]..sort((a, b) => a.title.compareTo(b.title));
          final q = normalizeForSearch(_query).text.trim();
          final books = q.isEmpty
              ? all
              : [
                  for (final b in all)
                    if (normalizeForSearch('${b.title} ${b.subject}').text
                        .contains(q))
                      b,
                ];
          // The categories, in the order the library sets (as in «الكتب»).
          final bySubject = <String, List<CatalogBook>>{};
          for (final b in books) {
            final s = b.subject.isEmpty ? 'كتب أخرى' : b.subject;
            bySubject.putIfAbsent(s, () => []).add(b);
          }
          final subjects = bySubject.keys.toList()
            ..sort((a, b) {
              final c = masdarRank(a).compareTo(masdarRank(b));
              return c != 0 ? c : a.compareTo(b);
            });
          final shown = _category == 'الكل' || !bySubject.containsKey(_category)
              ? subjects
              : [_category];
          return CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (all.length > 1)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, 12, side, 0),
                  sliver: SliverToBoxAdapter(
                    child: SearchBox(
                      hint: 'ابحث في مؤلفات ${widget.author}',
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ),
              if (subjects.length > 1)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, 12, side, 0),
                  sliver: SliverToBoxAdapter(
                    child: Pills(
                      labels: ['الكل', ...subjects],
                      selected: _category,
                      onSelected: (c) => setState(() => _category = c),
                    ),
                  ),
                ),
              if (books.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      all.isEmpty
                          ? 'لا توجد كتب لهذا المؤلف في المكتبة.'
                          : 'لا يوجد كتاب بهذا البحث.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Brand.muted),
                    ),
                  ),
                ),
              for (final subject in shown) ...[
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: side),
                  sliver: SliverToBoxAdapter(child: _shelfTitle(subject)),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: side),
                  sliver: CoverGridSliver(
                    count: bySubject[subject]!.length,
                    itemBuilder: (context, i) => _book(bySubject[subject]![i]),
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          );
        },
      ),
    );
  }
}
