import 'package:flutter/material.dart';

import '../book/book_text.dart';
import '../catalog/catalog_screen.dart' show formatSize;
import '../catalog/download_manager.dart';
import '../sync/google_account.dart';
import '../sync/sync_engine.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_widgets.dart';
import 'library_store.dart';

enum BookSort { mine, recent, title, author, subject }

const bookSortNames = {
  BookSort.mine: 'ترتيبي (اضغط مطولاً على الكتاب واسحبه)',
  BookSort.recent: 'آخر ما فُتح',
  BookSort.title: 'العنوان',
  BookSort.author: 'المؤلف',
  BookSort.subject: 'التصنيف',
};

/// "My books": what is on this device and in the account. Category buttons,
/// search, sort, and the covers with how far each book has been read.
class BooksTab extends StatefulWidget {
  const BooksTab({
    super.key,
    required this.library,
    required this.sync,
    required this.downloads,
    required this.account,
    required this.progress,
    required this.categories,
    required this.onOpen,
    required this.onMore,
    required this.onAccount,
    required this.onHistory,
    required this.onBrowse,
    required this.onDriveWarning,
  });

  final LibraryStore library;
  final SyncEngine sync;
  final DownloadManager downloads;
  final GoogleAccount account;
  final ReadProgress progress;

  /// The category buttons, "all" first: the same ones as in the catalogue.
  final List<String> categories;
  final void Function(BookEntry) onOpen;
  final void Function(BookEntry) onMore;
  final VoidCallback onAccount;
  final VoidCallback onHistory;
  final VoidCallback onBrowse;
  final VoidCallback onDriveWarning;

  @override
  State<BooksTab> createState() => _BooksTabState();
}

class _BooksTabState extends State<BooksTab> {
  String _category = 'الكل';
  String _query = '';
  BookSort _sort = BookSort.mine;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_progressNeeded);
    _progressNeeded();
  }

  @override
  void dispose() {
    widget.library.removeListener(_progressNeeded);
    super.dispose();
  }

  void _progressNeeded() => widget.progress.load(widget.library.ids);

  bool _loading(BookEntry b) {
    final id = b.catalogId;
    return id != null && widget.downloads.taskOf(id, b.part ?? 1) != null;
  }

  List<BookEntry> _shown(List<BookEntry> all) {
    final q = normalizeForSearch(_query).text.trim();
    final out = [
      for (final b in all)
        if ((_category == 'الكل' || b.subject == _category) &&
            (q.isEmpty ||
                normalizeForSearch('${b.title} ${b.author}').text.contains(q)))
          b,
    ];
    int byTitle(BookEntry a, BookEntry b) => a.title.compareTo(b.title);
    switch (_sort) {
      case BookSort.mine:
        out.sort((a, b) => a.rank.compareTo(b.rank));
      case BookSort.recent:
        break; // the library's own order
      case BookSort.title:
        out.sort(byTitle);
      case BookSort.author:
        out.sort((a, b) {
          final c = a.author.compareTo(b.author);
          return c != 0 ? c : byTitle(a, b);
        });
      case BookSort.subject:
        out.sort((a, b) {
          final c = a.subject.compareTo(b.subject);
          return c != 0 ? c : byTitle(a, b);
        });
    }
    return out;
  }

  Future<void> _pickSort() async {
    final picked = await showNotsSheet<BookSort>(
      context,
      builder: (context) => ChoiceSheet<BookSort>(
        title: 'الترتيب',
        current: _sort,
        choices: [for (final e in bookSortNames.entries) (e.key, e.value)],
      ),
    );
    if (picked != null) setState(() => _sort = picked);
  }

  String _subtitle(BookEntry b) {
    final lib = widget.library;
    if (lib.hasConflicts(b)) return 'صفحات تنتظر اختيارك';
    if (lib.isOnDevice(b)) return b.author;
    if (_loading(b)) return 'جارٍ التنزيل…';
    return 'في حسابك، اضغط لتنزيله';
  }

  Widget _hero(BuildContext context) => HeroHeader(
    child: Row(
      children: [
        const AppLogo(size: 46),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'قلم المصدر',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                  height: 1.2,
                ),
              ),
              Text(
                'اكتب على صفحات الكتاب',
                style: TextStyle(color: Color(0xFFCFDDF0), fontSize: 12.5),
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
  );

  Widget _driveWarning(BuildContext context) {
    final full = widget.sync.driveFull;
    return GestureDetector(
      onTap: widget.onDriveWarning,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: const Color(0xFFFBEFD6),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 19, color: Color(0xFF6B4E12)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                full
                    ? 'درايف ممتلئ. اضغط لنقل كل شيء إلى حساب آخر'
                    : 'درايف يقترب من الامتلاء. اضغط لنقل كل شيء إلى حساب آخر',
                style: const TextStyle(color: Color(0xFF6B4E12), fontSize: 13.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _conflictBanner(BookEntry b) => GestureDetector(
    onTap: () => widget.onOpen(b),
    child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFFBEFD6),
        borderRadius: BorderRadius.circular(15),
      ),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 19, color: Color(0xFF6B4E12)),
          SizedBox(width: 10),
          Text(
            'صفحة تنتظر اختيارك',
            style: TextStyle(color: Color(0xFF6B4E12), fontSize: 13.5),
          ),
        ],
      ),
    ),
  );

  Widget _empty() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 36, 8, 0),
    child: Column(
      children: [
        Icon(Icons.menu_book_outlined, size: 56, color: Brand.line),
        const SizedBox(height: 14),
        Text(
          'مكتبتك فارغة.\n\nنزّل كتاباً من خانة «الكتب»، أو أضف ملفاً من جهازك. تبقى كتابتك في ملف منفصل ولا يتغيّر الكتاب الأصلي.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Brand.muted, height: 1.7),
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: widget.onBrowse,
          icon: const Icon(Icons.storefront_outlined),
          label: const Text('تصفّح الكتب'),
        ),
        if (!widget.account.linked) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: widget.onAccount,
            icon: const Icon(Icons.login),
            label: const Text('تسجيل الدخول'),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final lib = widget.library;
    return ListenableBuilder(
      listenable: Listenable.merge([
        lib,
        widget.sync,
        widget.downloads,
        widget.account,
        widget.progress,
      ]),
      builder: (context, _) {
        final all = [for (final b in lib.books) if (!b.isNote) b];
        final shown = _shown(all);
        final conflict = all.where(lib.hasConflicts).firstOrNull;
        final warn =
            widget.sync.driveFull || (widget.sync.quota?.nearlyFull ?? false);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _hero(context)),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                sidePadding(context),
                0,
                sidePadding(context),
                0,
              ),
              sliver: SliverList.list(
                children: [
                  if (warn) _driveWarning(context),
                  if (conflict != null) _conflictBanner(conflict),
                  if (all.isEmpty)
                    _empty()
                  else ...[
                    Row(
                      children: [
                        Expanded(
                          child: Pills(
                            labels: widget.categories,
                            selected: _category,
                            onSelected: (c) => setState(() => _category = c),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SquareButton(
                          icon: Icons.sort,
                          tooltip: 'الترتيب',
                          onPressed: _pickSort,
                        ),
                      ],
                    ),
                    SectionTitle(
                      _category == 'الكل' ? 'كل الكتب' : _category,
                      count: all
                          .where((b) => _category == 'الكل' || b.subject == _category)
                          .length,
                    ),
                    SearchBox(
                      hint: 'ابحث في كتبك',
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 14),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _query.isNotEmpty
                              ? 'لا يوجد كتاب بهذا البحث.'
                              : 'لا توجد كتب في هذا التصنيف بعد.',
                          style: TextStyle(color: Brand.muted),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            if (shown.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  sidePadding(context),
                  0,
                  sidePadding(context),
                  130,
                ),
                sliver: CoverGridSliver(
                  count: shown.length,
                  itemBuilder: (context, i) {
                    final b = shown[i];
                    final item = BookGridItem(
                      book: b,
                      subtitle: _subtitle(b),
                      progress: widget.progress.shareOf(b.id),
                      inAccountOnly: !lib.isOnDevice(b),
                      onTap: () => widget.onOpen(b),
                      onMore: () => widget.onMore(b),
                    );
                    if (_sort != BookSort.mine) return item;
                    return _Movable(
                      book: b,
                      onDrop: (moved) => lib
                          .moveBook(moved, before: b)
                          .then((_) => widget.sync.requestSoon()),
                      child: item,
                    );
                  },
                ),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: 130)),
          ],
        );
      },
    );
  }
}

/// A sheet of choices with a tick on the current one. Pops with the value.
class ChoiceSheet<T> extends StatelessWidget {
  const ChoiceSheet({
    super.key,
    required this.title,
    required this.current,
    required this.choices,
  });

  final String title;
  final T current;
  final List<(T, String)> choices;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < choices.length; i++) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      title: Text(choices[i].$2),
                      trailing: choices[i].$1 == current
                          ? Icon(Icons.check, color: Brand.blue)
                          : null,
                      onTap: () => Navigator.pop(context, choices[i].$1),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "size" part of a book line: its megabytes, when known.
String sizeLine(BookEntry b) => b.size > 0 ? formatSize(b.size) : '';

/// In "my order" a book is held down and dragged onto another: it takes
/// that book's place, and the rest move along.
class _Movable extends StatelessWidget {
  const _Movable({required this.book, required this.onDrop, required this.child});

  final BookEntry book;
  final void Function(BookEntry moved) onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => DragTarget<BookEntry>(
        onWillAcceptWithDetails: (d) => d.data.id != book.id,
        onAcceptWithDetails: (d) => onDrop(d.data),
        builder: (context, incoming, _) => LongPressDraggable<BookEntry>(
          data: book,
          feedback: SizedBox(
            width: c.maxWidth,
            height: c.maxHeight,
            child: Opacity(
              opacity: 0.85,
              child: Material(color: Colors.transparent, child: child),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: child),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: incoming.isEmpty ? Colors.transparent : Brand.blue,
                width: 2,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
