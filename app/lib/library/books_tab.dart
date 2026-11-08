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
import 'parts_popup.dart';

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
    this.catalogTitle,
  });

  /// The title of a book of the server's library (for a book whose volumes
  /// stand together under one cover), or null when not known.
  final String? Function(String catalogId)? catalogTitle;

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

class _BooksTabState extends State<BooksTab>
    with SingleTickerProviderStateMixin {
  String _category = 'الكل';
  String _query = '';
  BookSort _sort = BookSort.mine;

  /// «ترتيب»: the books shiver and any of them can be dragged to another
  /// place. Outside it the books are plain, with nothing for dragging.
  bool _arranging = false;
  AnimationController? _shiver;

  void _setArranging(bool on) {
    setState(() {
      _arranging = on;
      if (on) {
        _sort = BookSort.mine;
        _shiver = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 260),
        )..repeat(reverse: true);
      } else {
        _shiver?.dispose();
        _shiver = null;
      }
    });
  }

  Widget _arrangeBar() => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 6, 6),
    decoration: BoxDecoration(
      color: Brand.blue.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Icon(Icons.open_with, size: 18, color: Brand.blue),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'اسحب أي كتاب إلى مكانه، ويُحفظ الترتيب.',
            style: TextStyle(fontSize: 13.5),
          ),
        ),
        FilledButton(
          onPressed: () => _setArranging(false),
          child: const Text('تم'),
        ),
      ],
    ),
  );

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_progressNeeded);
    _progressNeeded();
  }

  @override
  void dispose() {
    widget.library.removeListener(_progressNeeded);
    _shiver?.dispose();
    super.dispose();
  }

  /// Books whose reading progress was read. The others are read when they
  /// appear; a book closed in the reader is read again by the home screen.
  /// Reading every book's file on each change of the library used to cost
  /// hundreds of file reads during a sync.
  final _progressKnown = <String>{};

  void _progressNeeded() {
    final fresh = widget.library.ids.difference(_progressKnown);
    if (fresh.isEmpty) return;
    _progressKnown.addAll(fresh);
    widget.progress.load(fresh);
  }

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

  /// The books to show, the volumes of one book of the library together
  /// (in the order of their numbers), at the place of the first of them.
  List<List<BookEntry>> _grouped(List<BookEntry> books) {
    final groups = <List<BookEntry>>[];
    final byCatalog = <String, List<BookEntry>>{};
    for (final b in books) {
      final id = b.catalogId;
      if (id == null) {
        groups.add([b]);
        continue;
      }
      final g = byCatalog[id];
      if (g != null) {
        g.add(b);
      } else {
        groups.add(byCatalog[id] = [b]);
      }
    }
    for (final g in byCatalog.values) {
      g.sort((a, b) => (a.part ?? 0).compareTo(b.part ?? 0));
    }
    return groups;
  }

  /// The title of a group of volumes: the book's own, without the volume.
  String _groupTitle(List<BookEntry> g) {
    final first = g.first;
    final known = widget.catalogTitle?.call(first.catalogId!);
    if (known != null && known.isNotEmpty) return known;
    final t = first.title;
    final cut = t.lastIndexOf(' - ');
    return cut > 0 ? t.substring(0, cut) : t;
  }

  /// A tap on a book of several volumes: its volumes in a small card over
  /// it, and the one chosen opens.
  Future<void> _openGroup(BuildContext itemContext, List<BookEntry> g) async {
    final box = itemContext.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Rect.fromCenter(
            center: MediaQuery.sizeOf(context).center(Offset.zero),
            width: 1,
            height: 1,
          )
        : box.localToGlobal(Offset.zero) & box.size;
    final picked = await showPartsPopup(
      context,
      anchor: anchor,
      parts: g,
      progress: (b) => widget.progress.shareOf(b.id),
    );
    if (picked != null) widget.onOpen(picked);
  }

  Widget _gridItem(List<BookEntry> g) {
    final lib = widget.library;
    final b = g.first;
    if (g.length == 1) {
      final here = lib.isOnDevice(b);
      Widget item(String subtitle) => BookGridItem(
        book: b,
        subtitle: subtitle,
        progress: widget.progress.shareOf(b.id),
        inAccountOnly: !here,
        onTap: () => widget.onOpen(b),
        onMore: () => widget.onMore(b),
      );
      // Only a book still coming follows the downloads.
      return here
          ? item(_subtitle(b))
          : ListenableBuilder(
              listenable: widget.downloads,
              builder: (_, _) => item(_subtitle(b)),
            );
    }
    return Builder(
      builder: (itemContext) => BookGridItem(
        book: b,
        title: _groupTitle(g),
        subtitle: '${g.length} أجزاء',
        volumes: g.length,
        inAccountOnly: !g.any(lib.isOnDevice),
        onTap: () => _openGroup(itemContext, g),
        onMore: () => widget.onMore(b),
      ),
    );
  }

  /// Moves [moved] (with the other volumes of its book) before [before].
  Future<void> _move(BookEntry moved, {required BookEntry before}) async {
    final lib = widget.library;
    final id = moved.catalogId;
    final all = id == null
        ? [moved]
        : ([
            for (final b in lib.books)
              if (b.catalogId == id && !b.isNote) b,
          ]..sort((a, b) => (a.part ?? 0).compareTo(b.part ?? 0)));
    for (final b in all) {
      if (b.id != before.id) await lib.moveBook(b, before: before);
    }
    widget.sync.requestSoon();
  }

  Widget _hero(BuildContext context) => HeroHeader(
    child: Row(
      children: [
        const AppLogo(size: 34),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'قلم المصدر',
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
                style: const TextStyle(
                  color: Color(0xFF6B4E12),
                  fontSize: 13.5,
                ),
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
      // Not the sync nor the downloads: they change many times a second,
      // and the whole grid would be built again each time.
      listenable: Listenable.merge([lib, widget.account, widget.progress]),
      builder: (context, _) {
        final all = [
          for (final b in lib.books)
            if (!b.isNote) b,
        ];
        final shown = _grouped(_shown(all));
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
                  ListenableBuilder(
                    listenable: widget.sync,
                    builder: (context, _) {
                      final warn =
                          widget.sync.driveFull ||
                          (widget.sync.quota?.nearlyFull ?? false);
                      final conflict = all.where(lib.hasConflicts).firstOrNull;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (warn) _driveWarning(context),
                          if (conflict != null) _conflictBanner(conflict),
                        ],
                      );
                    },
                  ),
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
                          icon: Icons.open_with,
                          tooltip: 'ترتيب الكتب',
                          on: _arranging,
                          onPressed: () => _setArranging(!_arranging),
                        ),
                        const SizedBox(width: 8),
                        SquareButton(
                          icon: Icons.sort,
                          tooltip: 'الترتيب',
                          onPressed: _arranging ? null : _pickSort,
                        ),
                      ],
                    ),
                    if (_arranging) ...[
                      const SizedBox(height: 10),
                      _arrangeBar(),
                    ],
                    SectionTitle(
                      _category == 'الكل' ? 'كل الكتب' : _category,
                      count: all
                          .where(
                            (b) =>
                                _category == 'الكل' || b.subject == _category,
                          )
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
                    final g = shown[i];
                    final item = _gridItem(g);
                    final shiver = _shiver;
                    if (!_arranging || shiver == null) return item;
                    return _Movable(
                      book: g.first,
                      shiver: shiver,
                      tilt: i.isEven ? 1 : -1,
                      onDrop: (moved) => _move(moved, before: g.first),
                      // While arranging a tap does not open the book.
                      child: IgnorePointer(child: item),
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
  const _Movable({
    required this.book,
    required this.shiver,
    required this.tilt,
    required this.onDrop,
    required this.child,
  });

  final BookEntry book;

  /// Drives the small back-and-forth of every book while arranging.
  final Animation<double> shiver;

  /// Its direction, so neighbours move against each other.
  final double tilt;
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
          // Taken at once (a short touch), and a quick flick still scrolls.
          delay: const Duration(milliseconds: 120),
          feedback: SizedBox(
            width: c.maxWidth,
            height: c.maxHeight,
            child: Transform.scale(
              scale: 1.06,
              child: Opacity(
                opacity: 0.9,
                child: Material(color: Colors.transparent, child: child),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.2, child: child),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: incoming.isEmpty ? Colors.transparent : Brand.blue,
                width: 2,
              ),
            ),
            child: AnimatedBuilder(
              animation: shiver,
              builder: (context, child) => Transform.rotate(
                angle: tilt * (shiver.value - 0.5) * 0.03,
                child: child,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
