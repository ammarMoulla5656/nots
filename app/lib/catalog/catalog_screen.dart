import 'package:flutter/material.dart';

import '../library/book_widgets.dart';
import '../library/books_tab.dart' show ChoiceSheet;
import '../library/library_store.dart';
import '../sync/google_account.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_cover.dart';
import 'book_detail_screen.dart';
import 'catalog_models.dart';
import 'catalog_store.dart';
import 'download_manager.dart';

const _sortNames = {
  CatalogSort.newest: 'الأحدث',
  CatalogSort.title: 'العنوان',
  CatalogSort.author: 'المؤلف',
  CatalogSort.subject: 'التصنيف',
};

/// [text] kept as one left-to-right unit inside Arabic text; without this
/// "143 MB" comes out as "MB 143".
String ltr(String text) => '\u2066$text\u2069';

/// Short facts on one line, each staying in its place in Arabic text.
String joinFacts(Iterable<String> facts) =>
    facts.where((s) => s.isNotEmpty).map(ltrIfLatin).join(' \u200F·\u200F ');

/// Isolates [text] when it starts with a Latin letter, like "PDF".
String ltrIfLatin(String text) =>
    RegExp('^[A-Za-z]').hasMatch(text) ? ltr(text) : text;

String formatSize(int bytes) {
  if (bytes <= 0) return '';
  final mb = bytes / 1048576;
  return ltr(
    mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB',
  );
}

/// The "books" tab: every book of the library on the server, ready to
/// download. Browsing and searching run on the catalogue kept on the device,
/// so both are instant and work without a connection.
///
/// With no category, search or special order the books stand on shelves, one
/// per author; otherwise they are a plain grid.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.store,
    required this.downloads,
    required this.library,
    required this.account,
    required this.categories,
    required this.onOpen,
    required this.onAccount,
    required this.onHistory,
  });

  final CatalogStore store;
  final DownloadManager downloads;
  final LibraryStore library;
  final GoogleAccount account;

  /// The category buttons, "all" first.
  final List<String> categories;
  final void Function(BookEntry) onOpen;
  final VoidCallback onAccount;
  final VoidCallback onHistory;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  var _query = const CatalogQuery();
  List<CatalogBook>? _results;
  List<CatalogBook>? _resultsOf;

  List<CatalogBook> get _shown {
    final all = widget.store.books;
    if (_results == null || !identical(_resultsOf, all)) {
      _resultsOf = all;
      _results = runQuery(all, _query);
    }
    return _results!;
  }

  void _ask(CatalogQuery q) => setState(() {
    _query = q;
    _results = null;
  });

  Future<void> _pickSort() async {
    final picked = await showNotsSheet<CatalogSort>(
      context,
      builder: (_) => ChoiceSheet<CatalogSort>(
        title: 'الترتيب',
        current: _query.sort,
        choices: [for (final e in _sortNames.entries) (e.key, e.value)],
      ),
    );
    if (picked != null) _ask(_query.copyWith(sort: picked));
  }

  Future<void> _details(CatalogBook b) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BookDetailScreen(
        book: b,
        downloads: widget.downloads,
        library: widget.library,
        onOpen: widget.onOpen,
      ),
    ),
  );

  bool _owned(CatalogBook b) => b.parts.any(
    (p) => widget.library.installedCatalog(b.id, p.number) != null,
  );

  bool _loading(CatalogBook b) =>
      b.parts.any((p) => widget.downloads.taskOf(b.id, p.number) != null);

  Widget _hero() => HeroHeader(
    bottom: 4,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'الكتب',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            HeroButton(
              icon: Icons.schedule,
              tooltip: 'آخر ١٠ كتب',
              onPressed: widget.onHistory,
            ),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: widget.account,
              builder: (_, _) => HeroButton(
                icon: Icons.person_outline,
                photo: widget.account.photo,
                tooltip: 'الحساب',
                dot: widget.account.linked,
                onPressed: widget.onAccount,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(16),
          ),
          child: TextField(
            onChanged: (v) => _ask(_query.copyWith(text: v)),
            style: const TextStyle(color: Colors.white, fontSize: 15),
            cursorColor: Colors.white,
            decoration: InputDecoration(
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintText: 'ابحث بالعنوان أو المؤلف أو المحقق',
              hintStyle: const TextStyle(
                color: Color(0xFFCFDDF0),
                fontSize: 14.5,
              ),
              prefixIcon: Icon(
                Icons.search,
                size: 20,
                color: Colors.white.withValues(alpha: 0.85),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _empty(CatalogStore s) {
    final String text;
    if (s.books.isEmpty) {
      text = s.failed
          ? 'تعذّر الاتصال بالمكتبة. اسحب للأسفل لإعادة المحاولة.'
          : 'لا توجد كتب في المكتبة بعد.';
    } else {
      text = 'لا يوجد كتاب بهذا البحث.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 130),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Brand.muted, height: 1.7),
      ),
    );
  }

  Widget _shelfBook(CatalogBook b, double width) => SizedBox(
    width: width,
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _details(b),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cover(b, width),
          const SizedBox(height: 9),
          Text(
            b.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
          Text(
            b.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Brand.muted),
          ),
        ],
      ),
    ),
  );

  /// A book's cover; its badge (being downloaded, owned) follows the
  /// downloads by itself.
  Widget _cover(CatalogBook b, double width) => ListenableBuilder(
    listenable: widget.downloads,
    builder: (_, _) => BookCover(
      b.cover,
      width: width,
      badge: _loading(b)
          ? Icons.downloading
          : _owned(b)
          ? Icons.check
          : null,
    ),
  );

  /// One shelf per category, in the order the Masdar app lists them.
  List<MapEntry<String, List<CatalogBook>>> _shelves(List<CatalogBook> books) {
    final by = <String, List<CatalogBook>>{};
    for (final b in books) {
      by
          .putIfAbsent(b.subject.isEmpty ? 'كتب أخرى' : b.subject, () => [])
          .add(b);
    }
    return by.entries.toList()..sort((a, b) {
      final c = masdarRank(a.key).compareTo(masdarRank(b.key));
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Not the downloads: they tick five times a second, and only the
      // covers' badges follow them.
      listenable: Listenable.merge([widget.store, widget.library]),
      builder: (context, _) {
        final s = widget.store;
        final books = _shown;
        final shelfMode =
            _query.text.trim().isEmpty &&
            _query.subject.isEmpty &&
            _query.sort == CatalogSort.newest;
        final wide = MediaQuery.sizeOf(context).width >= 700;
        final shelfWidth = wide ? 130.0 : 112.0;
        final shelves = shelfMode ? _shelves(books) : const [];
        return RefreshIndicator(
          edgeOffset: 120,
          onRefresh: s.refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _hero()),
              if (s.refreshing)
                const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: sidePadding(context)),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Pills(
                          labels: widget.categories,
                          selected: _query.subject.isEmpty
                              ? 'الكل'
                              : _query.subject,
                          onSelected: (c) => _ask(
                            _query.copyWith(subject: c == 'الكل' ? '' : c),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SquareButton(
                        icon: Icons.sort,
                        tooltip: 'الترتيب',
                        on: _query.sort != CatalogSort.newest,
                        onPressed: _pickSort,
                      ),
                    ],
                  ),
                ),
              ),
              if (books.isEmpty)
                SliverToBoxAdapter(child: _empty(s))
              else if (shelfMode)
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 130),
                  sliver: SliverList.builder(
                    itemCount: shelves.length,
                    itemBuilder: (context, i) {
                      final shelf = shelves[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              sidePadding(context),
                              22,
                              sidePadding(context),
                              12,
                            ),
                            child: Row(
                              children: [
                                Transform.rotate(
                                  angle: 0.785398,
                                  child: Container(
                                    width: 9,
                                    height: 9,
                                    color: Brand.gold,
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    shelf.key,
                                    style: const TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w900,
                                      height: 1.45,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            height: shelfWidth / BookCover.ratio + 58,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              padding: EdgeInsets.symmetric(
                                horizontal: sidePadding(context),
                              ),
                              itemCount: shelf.value.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 13),
                              itemBuilder: (_, k) =>
                                  _shelfBook(shelf.value[k], shelfWidth),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    sidePadding(context),
                    16,
                    sidePadding(context),
                    130,
                  ),
                  sliver: CoverGridSliver(
                    count: books.length,
                    itemBuilder: (context, i) {
                      final b = books[i];
                      return LayoutBuilder(
                        builder: (context, box) => InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _details(b),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _cover(b, box.maxWidth),
                              const SizedBox(height: 9),
                              Text(
                                b.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  height: 1.45,
                                ),
                              ),
                              Text(
                                b.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Brand.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
