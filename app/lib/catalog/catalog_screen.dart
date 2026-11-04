import 'package:flutter/material.dart';

import '../library/library_store.dart';
import 'book_detail_screen.dart';
import 'catalog_models.dart';
import 'catalog_store.dart';
import 'cover_image.dart';
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

/// The "download" tab: every book of the library on the server. Browsing and
/// searching run on the catalogue kept on the device, so both are instant
/// and work without a connection.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.store,
    required this.downloads,
    required this.library,
    required this.onOpen,
  });

  final CatalogStore store;
  final DownloadManager downloads;
  final LibraryStore library;
  final void Function(BookEntry) onOpen;

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

  Future<void> _pick(
    String title,
    String current,
    String Function(CatalogBook) field,
    CatalogQuery Function(String value) apply,
  ) async {
    final values = valuesOf(widget.store.books, field);
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.7,
        child: _ValuePicker(title: title, values: values, current: current),
      ),
    );
    if (picked != null) _ask(apply(picked));
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

  Widget _filter(
    String name,
    String value,
    String Function(CatalogBook) field,
    CatalogQuery Function(String) apply,
  ) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 6),
    child: FilterChip(
      label: Text(value.isEmpty ? name : value),
      selected: value.isNotEmpty,
      onSelected: (_) => _pick(name, value, field, apply),
    ),
  );

  Widget _filters() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 6),
          child: PopupMenuButton<CatalogSort>(
            tooltip: 'الترتيب',
            onSelected: (s) => _ask(_query.copyWith(sort: s)),
            itemBuilder: (_) => [
              for (final e in _sortNames.entries)
                CheckedPopupMenuItem(
                  value: e.key,
                  checked: e.key == _query.sort,
                  child: Text(e.value),
                ),
            ],
            child: Chip(
              avatar: const Icon(Icons.sort, size: 18),
              label: Text(_sortNames[_query.sort]!),
            ),
          ),
        ),
        _filter(
          'التصنيف',
          _query.subject,
          (b) => b.subject,
          (v) => _query.copyWith(subject: v),
        ),
        _filter(
          'المؤلف',
          _query.author,
          (b) => b.author,
          (v) => _query.copyWith(author: v),
        ),
        _filter(
          'اللغة',
          _query.language,
          (b) => b.language,
          (v) => _query.copyWith(language: v),
        ),
        _filter(
          'الناشر',
          _query.publisher,
          (b) => b.publisher,
          (v) => _query.copyWith(publisher: v),
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
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
          child: Text(text, textAlign: TextAlign.center),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.store,
        widget.downloads,
        widget.library,
      ]),
      builder: (context, _) {
        final s = widget.store;
        final books = _shown;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'ابحث بالعنوان أو المؤلف أو المحقق',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _ask(_query.copyWith(text: v)),
              ),
            ),
            _filters(),
            if (s.refreshing) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: RefreshIndicator(
                onRefresh: s.refresh,
                child: books.isEmpty
                    ? _empty(s)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                        itemCount: books.length,
                        itemExtent: 104,
                        itemBuilder: (_, i) => _BookTile(
                          book: books[i],
                          library: widget.library,
                          downloads: widget.downloads,
                          onTap: () => _details(books[i]),
                        ),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.library,
    required this.downloads,
    required this.onTap,
  });

  final CatalogBook book;
  final LibraryStore library;
  final DownloadManager downloads;
  final VoidCallback onTap;

  String get _facts {
    final formats = {for (final p in book.parts) p.formatName}.join(' / ');
    return joinFacts([
      formats,
      if (book.multiPart) '${book.partsCount} أجزاء',
      formatSize(book.totalSize),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final have = book.parts
        .where((p) => library.byCatalog(book.id, p.number) != null)
        .length;
    final loading = book.parts.any(
      (p) => downloads.taskOf(book.id, p.number) != null,
    );
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              CoverImage(book.cover, width: 58, height: 80),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall,
                    ),
                    if (book.author.isNotEmpty)
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    const SizedBox(height: 2),
                    Text(
                      _facts,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall,
                    ),
                  ],
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (have > 0)
                Icon(
                  have == book.parts.length
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The values of one field, with a box to narrow them down. Returns the one
/// chosen; an empty string means "all".
class _ValuePicker extends StatefulWidget {
  const _ValuePicker({
    required this.title,
    required this.values,
    required this.current,
  });

  final String title;
  final List<String> values;
  final String current;

  @override
  State<_ValuePicker> createState() => _ValuePickerState();
}

class _ValuePickerState extends State<_ValuePicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final shown = widget.values.where((v) => v.contains(_q)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: InputDecoration(
              hintText: widget.title,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        ListTile(
          title: const Text('الكل'),
          selected: widget.current.isEmpty,
          onTap: () => Navigator.pop(context, ''),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(shown[i]),
              selected: shown[i] == widget.current,
              onTap: () => Navigator.pop(context, shown[i]),
            ),
          ),
        ),
      ],
    );
  }
}
