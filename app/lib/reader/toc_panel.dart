import 'package:flutter/material.dart';

import '../book/book_text.dart';

/// One line of the table of contents, with its PDF page.
typedef TocEntry = ({String title, int level, int pdfPage});

/// Table of contents in a side drawer: headings of the linked Word text (or
/// the PDF's own outline), the current section highlighted, filterable.
class TocPanel extends StatefulWidget {
  const TocPanel({
    super.key,
    required this.title,
    required this.entries,
    required this.linkedSource,
    required this.currentPdfPage,
    required this.onOpen,
    required this.onLink,
    required this.onUnlink,
    this.embedded = false,
  });

  final String title;
  final List<TocEntry> entries;

  /// Name of the linked Word file, or null when none is linked.
  final String? linkedSource;
  final int currentPdfPage;
  final ValueChanged<int> onOpen;
  final VoidCallback onLink;

  /// Null when the text cannot be unlinked (it is part of the PDF).
  final VoidCallback? onUnlink;

  /// The text is the PDF's own word map (made by nots-cook).
  final bool embedded;

  /// Entries built from the linked book text.
  static List<TocEntry> fromBook(BookText book) => [
    for (final h in book.headings)
      (title: h.title, level: h.level, pdfPage: book.pdfPageOf(h.page)),
  ];

  @override
  State<TocPanel> createState() => _TocPanelState();
}

class _TocPanelState extends State<TocPanel> {
  static const _rowHeight = 46.0;
  String _filter = '';
  late final ScrollController _scroll;

  int get _currentIndex {
    var idx = -1;
    for (var i = 0; i < widget.entries.length; i++) {
      if (widget.entries[i].pdfPage > widget.currentPdfPage) break;
      idx = i;
    }
    return idx;
  }

  @override
  void initState() {
    super.initState();
    // Open with the current section in view.
    final i = _currentIndex;
    _scroll = ScrollController(
      initialScrollOffset: i <= 3 ? 0 : (i - 3) * _rowHeight,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _currentIndex;
    final q = normalizeForSearch(_filter).text.trim();
    final visible = <int>[
      for (var i = 0; i < widget.entries.length; i++)
        if (q.isEmpty ||
            normalizeForSearch(widget.entries[i].title).text.contains(q))
          i,
    ];
    return Drawer(
      width: 330,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('الفهرس', style: theme.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                widget.title,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.entries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'ابحث في العناوين',
                    prefixIcon: Icon(Icons.filter_list),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
            Expanded(
              child: widget.entries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'لا يوجد فهرس لهذا الملف.\n\nاربط ملف Word (docx) للكتاب نفسه، مطابقاً للأصل صفحةً بصفحة، فيظهر فهرسه هنا ويعمل البحث في نصه.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemExtent: _rowHeight,
                      itemCount: visible.length,
                      itemBuilder: (context, k) {
                        final i = visible[k];
                        final e = widget.entries[i];
                        final isCurrent = i == current;
                        return ListTile(
                          dense: true,
                          selected: isCurrent,
                          selectedTileColor: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.5),
                          contentPadding: EdgeInsetsDirectional.only(
                            start: 12.0 + 16 * (e.level - 1).clamp(0, 4),
                            end: 12,
                          ),
                          title: Text(
                            e.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: e.level == 1 ? FontWeight.bold : null,
                              fontSize: e.level == 1 ? 15 : 14,
                            ),
                          ),
                          trailing: Text(
                            '${e.pdfPage}',
                            style: theme.textTheme.bodySmall,
                          ),
                          onTap: () => widget.onOpen(e.pdfPage),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            if (widget.linkedSource == null)
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('ربط ملف Word (docx) بهذا الكتاب'),
                subtitle: const Text('للفهرس والبحث السريع في النص'),
                onTap: widget.onLink,
              )
            else
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(
                  widget.linkedSource!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  widget.embedded
                      ? 'نص الكتاب مدمج في ملفه: كل كلمة مربوطة بمكانها'
                      : 'ملف النص المربوط',
                ),
                trailing: widget.onUnlink == null
                    ? null
                    : IconButton(
                        tooltip: 'إلغاء الربط',
                        icon: const Icon(Icons.link_off),
                        onPressed: widget.onUnlink,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
