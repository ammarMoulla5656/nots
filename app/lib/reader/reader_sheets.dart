import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ink/tool_controller.dart';
import '../library/home_sheets.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'toc_panel.dart';
import 'tool_layout.dart';

/// The contents of the book, and nothing else. Pops with the PDF page.
class TocSheet extends StatefulWidget {
  const TocSheet({
    super.key,
    required this.entries,
    required this.currentPdfPage,
    required this.onLink,
  });

  final List<TocEntry> entries;
  final int currentPdfPage;

  /// Linking a Word file is how a book without contents gets them.
  final VoidCallback onLink;

  @override
  State<TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<TocSheet> {
  static const _row = 46.0;
  late final ScrollController _scroll;

  int get _current {
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
    final i = _current;
    _scroll = ScrollController(initialScrollOffset: i <= 3 ? 0 : (i - 3) * _row);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('الفهرس'),
          if (widget.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'لا يوجد فهرس لهذا الملف.\n\nاربط ملف Word (docx) للكتاب نفسه، مطابقاً للأصل صفحةً بصفحة، فيظهر فهرسه هنا ويعمل البحث في نصه.',
                    style: TextStyle(color: Brand.muted, height: 1.7),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    onPressed: widget.onLink,
                    icon: const Icon(Icons.link),
                    label: const Text('ربط ملف Word (docx)'),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                controller: _scroll,
                itemExtent: _row,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                itemCount: widget.entries.length,
                itemBuilder: (context, i) {
                  final e = widget.entries[i];
                  final on = i == current;
                  return InkWell(
                    borderRadius: BorderRadius.circular(11),
                    onTap: () => Navigator.pop(context, e.pdfPage),
                    child: Container(
                      decoration: BoxDecoration(
                        color: on ? Brand.tint : null,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      padding: EdgeInsetsDirectional.only(
                        start: 10.0 + 16 * (e.level - 1).clamp(0, 4),
                        end: 10,
                      ),
                      alignment: AlignmentDirectional.centerStart,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: e.level == 1 ? 15 : 14,
                                fontWeight: on || e.level == 1
                                    ? FontWeight.w700
                                    : null,
                                color: on
                                    ? Brand.onTint
                                    : e.level == 1
                                    ? Brand.blue
                                    : e.level >= 3
                                    ? Brand.muted
                                    : null,
                              ),
                            ),
                          ),
                          Text(
                            '${e.pdfPage}',
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
  }
}

/// What the three dots offer. Pops with the id of the row chosen.
class ReaderMenuSheet extends StatelessWidget {
  const ReaderMenuSheet({
    super.key,
    required this.annotated,
    required this.marked,
    required this.isBook,
    required this.linked,
    required this.canUnlink,
  });

  final int annotated;
  final int marked;
  final bool isBook;

  /// A Word file (or a word map) gives this book its text.
  final bool linked;
  final bool canUnlink;

  @override
  Widget build(BuildContext context) {
    void pick(String id) => Navigator.pop(context, id);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader(''),
            ActionRows(
              rows: [
                ActionRow(
                  Icons.fullscreen,
                  'الشاشة الصافية',
                  () => pick('clean'),
                  subtitle: 'تختفي الأشرطة وتبقى الصفحة وحدها',
                ),
                ActionRow(Icons.ios_share, 'تصدير ومشاركة', () => pick('export')),
                ActionRow(
                  Icons.edit_note,
                  'المكتوب عليها',
                  () => pick('annotated'),
                  subtitle: '$annotated صفحة',
                ),
                ActionRow(
                  Icons.bookmark_border,
                  'العلامات',
                  () => pick('marks'),
                  subtitle: '$marked صفحة',
                ),
                ActionRow(Icons.grid_view, 'كل الصفحات', () => pick('pages')),
                if (isBook && !linked)
                  ActionRow(
                    Icons.link,
                    'ربط ملف Word (docx)',
                    () => pick('link'),
                    subtitle: 'للفهرس والبحث السريع في النص',
                  ),
                if (isBook && linked && canUnlink)
                  ActionRow(
                    Icons.link_off,
                    'إلغاء ربط ملف Word',
                    () => pick('unlink'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Arranging the tools: drag one between the bar and the box, or tap it to
/// send it to the other.
class ToolSettingsSheet extends StatelessWidget {
  const ToolSettingsSheet({super.key, required this.layout, required this.isBook});

  final ToolLayout layout;
  final bool isBook;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: ListenableBuilder(
          listenable: layout,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('إعدادات الأدوات'),
              Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'اسحب الأداة بين الشريط والمربع أو غيّر ترتيبها، أو اضغطها لنقلها.',
                  style: TextStyle(color: Brand.muted, height: 1.7, fontSize: 13.5),
                ),
              ),
              _zone('في الشريط', true),
              _zone('داخل المربع', false),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: layout.reset,
                      child: const Text('الترتيب الأصلي'),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('تم'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(ReaderTool t) => Container(
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: Brand.tint,
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(t.icon, size: 20, color: Brand.onTint),
        const SizedBox(width: 6),
        Text(
          t.label,
          style: TextStyle(
            fontSize: 13.5,
            color: Brand.onTint,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    ),
  );

  Widget _zone(String title, bool bar) {
    final tools = [
      for (final t in bar ? layout.bar : layout.box)
        if (isBook || !t.forBooksOnly) t,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Brand.muted,
            ),
          ),
        ),
        DragTarget<ReaderTool>(
          onAcceptWithDetails: (d) => layout.place(d.data, bar: bar),
          builder: (context, hovering, _) => Container(
            constraints: const BoxConstraints(minHeight: 62),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: hovering.isNotEmpty ? Brand.tint : Brand.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: hovering.isNotEmpty ? Brand.blue : Brand.line,
                width: 1.5,
              ),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in tools)
                  DragTarget<ReaderTool>(
                    onAcceptWithDetails: (d) {
                      final list = bar ? layout.bar : layout.box;
                      final at = list.indexOf(t);
                      layout.place(d.data, bar: bar, index: at);
                    },
                    builder: (context, _, _) => Draggable<ReaderTool>(
                      data: t,
                      feedback: Material(
                        color: Colors.transparent,
                        elevation: 6,
                        borderRadius: BorderRadius.circular(13),
                        child: _chip(t),
                      ),
                      childWhenDragging: Opacity(opacity: 0.3, child: _chip(t)),
                      child: GestureDetector(
                        onTap: () => layout.flip(t),
                        child: _chip(t),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A sheet to type a text, a note or a comment in, with (for a text box) its
/// size. Pops with the [TextEntry] or null.
typedef TextEntry = ({String text, bool delete, double? fontSize});

class TextEntrySheet extends StatefulWidget {
  const TextEntrySheet({
    super.key,
    required this.title,
    this.initial = '',
    this.allowDelete = false,
    this.fontSize,
    this.color,
  });

  final String title;
  final String initial;
  final bool allowDelete;

  /// The size of a text box, or null for a note.
  final double? fontSize;
  final int? color;

  @override
  State<TextEntrySheet> createState() => _TextEntrySheetState();
}

class _TextEntrySheetState extends State<TextEntrySheet> {
  late final _controller = TextEditingController(text: widget.initial);
  late double? _size = widget.fontSize;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final range = ToolController.textSizeRange;
    final size = _size;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(widget.title),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                style: size == null
                    ? null
                    : TextStyle(
                        fontSize: size.clamp(12.0, 34.0),
                        color: widget.color == null ? null : Color(widget.color!),
                      ),
              ),
              if (size != null)
                Row(
                  children: [
                    IconButton(
                      tooltip: 'أصغر',
                      icon: const Icon(Icons.text_decrease),
                      onPressed: () =>
                          setState(() => _size = math.max(range.min, size - 2)),
                    ),
                    Expanded(
                      child: Slider(
                        min: range.min,
                        max: range.max,
                        value: size.clamp(range.min, range.max),
                        onChanged: (v) => setState(() => _size = v),
                      ),
                    ),
                    IconButton(
                      tooltip: 'أكبر',
                      icon: const Icon(Icons.text_increase),
                      onPressed: () =>
                          setState(() => _size = math.min(range.max, size + 2)),
                    ),
                    SizedBox(
                      width: 30,
                      child: Text('${size.round()}', textAlign: TextAlign.center),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (widget.allowDelete) ...[
                    Expanded(
                      child: TextButton(
                        style: TextButton.styleFrom(foregroundColor: Brand.red),
                        onPressed: () => Navigator.pop<TextEntry>(context, (
                          text: widget.initial,
                          delete: true,
                          fontSize: _size,
                        )),
                        child: const Text('حذف'),
                      ),
                    ),
                    const SizedBox(width: 9),
                  ],
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء'),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop<TextEntry>(context, (
                        text: _controller.text,
                        delete: false,
                        fontSize: _size,
                      )),
                      child: const Text('حفظ'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A note or a word's comment, shown to read. Pops with 'delete' or 'edit'.
class NoteViewSheet extends StatelessWidget {
  const NoteViewSheet({super.key, required this.text, this.quote = '', this.color});

  final String text;
  final String quote;
  final int? color;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('ملاحظة'),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (quote.isNotEmpty) ...[
                      Text(
                        '«$quote»',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: color == null ? Brand.muted : Color(color!),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    SelectableText(
                      text.isEmpty ? 'لا يوجد تعليق بعد.' : text,
                      style: const TextStyle(fontSize: 16, height: 1.9),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: Brand.red),
                    onPressed: () => Navigator.pop(context, 'delete'),
                    child: const Text('حذف'),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.pop(context, 'edit'),
                    child: const Text('تعديل'),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('إغلاق'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
