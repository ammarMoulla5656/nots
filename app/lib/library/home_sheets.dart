import 'package:flutter/material.dart';

import '../catalog/book_cover.dart';
import '../notes/paper.dart';
import '../ui/brand_widgets.dart';
import '../ui/color_wheel.dart';
import '../ui/theme.dart';
import 'book_widgets.dart';
import 'library_store.dart';

/// What the "new" star offers: a sheet of paper (plain, lined or squared,
/// in the colours chosen), or adding a book from the device. Pops with the
/// [PaperStyle] chosen, or [addBook].
class NewPaperSheet extends StatefulWidget {
  const NewPaperSheet({super.key});

  /// Popped when the user asked to add a book instead.
  static const addBook = 'book';

  @override
  State<NewPaperSheet> createState() => _NewPaperSheetState();
}

class _NewPaperSheetState extends State<NewPaperSheet> {
  var _style = const PaperStyle(
    kind: PaperKind.lined,
    paper: 0xFFFBF8F1,
    line: 0xFFD6CFBE,
  );
  final _extraPaper = <int>[];
  final _extraLine = <int>[];

  Future<void> _custom(bool paper) async {
    final c = await showColorWheelDialog(
      context,
      Color(paper ? _style.paper : _style.line),
    );
    if (c == null) return;
    final v = c.toARGB32();
    setState(() {
      (paper ? _extraPaper : _extraLine).add(v);
      _style = paper ? _style.copyWith(paper: v) : _style.copyWith(line: v);
    });
  }

  Widget _swatches(List<int> colors, int selected, bool paper) {
    final all = [...colors, ...(paper ? _extraPaper : _extraLine)];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final c in all)
            GestureDetector(
              onTap: () => setState(
                () => _style = paper
                    ? _style.copyWith(paper: c)
                    : _style.copyWith(line: c),
              ),
              child: Container(
                width: 38,
                height: 38,
                margin: const EdgeInsetsDirectional.only(end: 10, top: 3, bottom: 3),
                decoration: BoxDecoration(
                  color: Color(c),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: c == selected ? Brand.blue : Brand.line,
                    width: c == selected ? 3 : 1,
                  ),
                ),
              ),
            ),
          GestureDetector(
            onTap: () => _custom(paper),
            child: Container(
              width: 38,
              height: 38,
              margin: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                gradient: const SweepGradient(
                  colors: [
                    Color(0xFFEE3333),
                    Color(0xFFFFCC33),
                    Color(0xFF33CC66),
                    Color(0xFF3399EE),
                    Color(0xFFAA33EE),
                    Color(0xFFEE3333),
                  ],
                ),
              ),
              child: const Icon(Icons.add, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String s) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 16, 2, 6),
    child: Text(
      s,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: Brand.muted,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('ورقة جديدة'),
            Row(
              children: [
                for (final k in PaperKind.values) ...[
                  if (k != PaperKind.values.first) const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _style = _style.copyWith(kind: k)),
                      child: Column(
                        children: [
                          PaperPreview(
                            _style.copyWith(kind: k),
                            selected: k == _style.kind,
                          ),
                          const SizedBox(height: 7),
                          Text(
                            k.title,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: k == _style.kind
                                  ? FontWeight.w700
                                  : null,
                              color: k == _style.kind ? Brand.blue : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
            _label('لون الورق'),
            _swatches(paperColors, _style.paper, true),
            if (_style.kind != PaperKind.blank) ...[
              _label('لون الخطوط'),
              _swatches(lineColors, _style.line, false),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, _style),
              icon: const Icon(Icons.add),
              label: const Text('إنشاء الورقة'),
            ),
            const SizedBox(height: 12),
            Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('إضافة كتاب'),
                subtitle: const Text('ملف PDF أو ملف نوتس من جهازك'),
                onTap: () => Navigator.pop(context, NewPaperSheet.addBook),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last ten books opened, with how far the reader got in each.
class HistorySheet extends StatelessWidget {
  const HistorySheet({
    super.key,
    required this.books,
    required this.progress,
  });

  final List<BookEntry> books;
  final ReadProgress progress;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('آخر ١٠ كتب فتحتها'),
          if (books.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 28),
              child: Text(
                'لم تفتح كتاباً بعد.',
                style: TextStyle(color: Brand.muted),
              ),
            )
          else
            Flexible(
              child: ListenableBuilder(
                listenable: progress,
                builder: (context, _) => ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                  children: [
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var i = 0; i < books.length; i++) ...[
                            if (i > 0) const Divider(),
                            _Row(
                              book: books[i],
                              page: progress.of(books[i].id),
                              share: progress.shareOf(books[i].id),
                              onTap: () => Navigator.pop(context, books[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.book,
    required this.page,
    required this.share,
    required this.onTap,
  });

  final BookEntry book;
  final ({int page, int count})? page;
  final double? share;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = page;
    final where = p == null
        ? 'لم تبدأ القراءة بعد'
        : p.count > 0
        ? 'وصلت إلى صفحة ${p.page} من ${p.count}'
        : 'وصلت إلى صفحة ${p.page}';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(width: 42, child: BookCover(book.cover, width: 42)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    where,
                    style: TextStyle(fontSize: 12.5, color: Brand.muted),
                  ),
                  if (share != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: share,
                        minHeight: 4,
                        color: Brand.gold,
                        backgroundColor: Brand.line,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (share != null) ...[
              const SizedBox(width: 10),
              Text(
                '${(share! * 100).round()}٪',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Brand.blue,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Rows in a card, for sheets of actions.
class ActionRows extends StatelessWidget {
  const ActionRows({super.key, required this.rows});

  final List<ActionRow> rows;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(),
          ListTile(
            leading: Icon(
              rows[i].icon,
              color: rows[i].danger ? Brand.red : Brand.blue,
            ),
            title: Text(
              rows[i].title,
              style: TextStyle(color: rows[i].danger ? Brand.red : null),
            ),
            subtitle: rows[i].subtitle == null ? null : Text(rows[i].subtitle!),
            onTap: rows[i].onTap,
          ),
        ],
      ],
    ),
  );
}

class ActionRow {
  const ActionRow(
    this.icon,
    this.title,
    this.onTap, {
    this.subtitle,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool danger;
  final VoidCallback onTap;
}
