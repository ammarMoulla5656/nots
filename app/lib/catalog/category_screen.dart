import 'package:flutter/material.dart';

import '../library/book_widgets.dart' show CoverGridSliver;
import '../library/library_store.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_cover.dart';
import 'book_detail_screen.dart';
import 'catalog_models.dart';
import 'catalog_store.dart';
import 'download_manager.dart';

/// All the books of one category of the library, in a grid like «كتبي»: a
/// tick on the ones already downloaded; a tap opens the book's page.
class CategoryScreen extends StatelessWidget {
  const CategoryScreen({
    super.key,
    required this.subject,
    required this.store,
    required this.downloads,
    required this.library,
    required this.onOpen,
  });

  /// The category as the books name it ('كتب أخرى' for the ones with none).
  final String subject;
  final CatalogStore store;
  final DownloadManager downloads;
  final LibraryStore library;
  final void Function(BookEntry) onOpen;

  static Future<void> open(
    BuildContext context, {
    required String subject,
    required CatalogStore store,
    required DownloadManager downloads,
    required LibraryStore library,
    required void Function(BookEntry) onOpen,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CategoryScreen(
        subject: subject,
        store: store,
        downloads: downloads,
        library: library,
        onOpen: onOpen,
      ),
    ),
  );

  bool _owned(CatalogBook b) =>
      b.parts.any((p) => library.installedCatalog(b.id, p.number) != null);

  @override
  Widget build(BuildContext context) {
    final side = sidePadding(context);
    return Scaffold(
      backgroundColor: Brand.paper,
      appBar: AppBar(title: Text(subject)),
      body: ListenableBuilder(
        listenable: Listenable.merge([store, library, downloads]),
        builder: (context, _) {
          final books = [
            for (final b in store.books)
              if ((b.subject.isEmpty ? 'كتب أخرى' : b.subject) == subject) b,
          ]..sort((a, b) => a.title.compareTo(b.title));
          return CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              if (books.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      'لا توجد كتب في هذا التصنيف بعد.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Brand.muted),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, 0, side, 40),
                  sliver: CoverGridSliver(
                    count: books.length,
                    itemBuilder: (context, i) {
                      final b = books[i];
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => BookDetailScreen(
                              book: b,
                              downloads: downloads,
                              library: library,
                              onOpen: onOpen,
                              store: store,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            BookCover(
                              b.cover,
                              badge: _owned(b) ? Icons.check : null,
                            ),
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
                              b.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Brand.muted,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
