import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../book/book_link_store.dart';
import '../book/book_text.dart';
import '../export/exporter.dart';
import '../ink/ink_document.dart';
import '../ink/ink_store.dart';
import '../ink/item_painter.dart';
import '../library/library_store.dart';
import '../ink/note_items.dart';
import '../ink/page_ink_overlay.dart';
import '../ink/selection.dart';
import '../ink/shapes.dart';
import '../ink/stroke.dart';
import '../ink/tool_controller.dart';
import '../ink/words.dart';
import '../ui/color_wheel.dart';
import 'pages_sheet.dart';
import 'reader_prefs.dart';
import 'search_page.dart';
import 'toc_panel.dart';
import 'touch_navigator.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.library, required this.book});

  final LibraryStore library;
  final BookEntry book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

/// Result of the text dialog. [fontSize] is null for pins and comments.
typedef TextDialogResult = ({String text, bool delete, double? fontSize});

class _ReaderScreenState extends State<ReaderScreen> {
  final _tools = ToolController();
  final _viewer = PdfViewerController();
  final _toolbarOpen = ValueNotifier<bool>(true);
  final _words = <int, Future<List<WordBox>>>{};
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  InkStore? _store;
  SelectionController? _selection;
  Object? _error;

  /// Word text linked to this PDF (table of contents and search), if any.
  BookText? _book;

  /// The PDF's own outline, used when no Word text is linked.
  List<TocEntry> _outline = const [];

  /// The search result being shown, with the whole result list.
  SearchPick? _search;

  /// Last page read and bookmarks of this book.
  ReaderPrefs? _prefs;
  bool _restored = false;

  /// Toolbar at the top of the page (default, like Notability) or bottom.
  bool _toolbarTop = true;

  /// Word boxes already loaded, per page, for instant taps.
  final _wordsReady = <int, List<WordBox>>{};

  @override
  void initState() {
    super.initState();
    _tools.addListener(_onToolChanged);
    ReaderPrefs.open(widget.book.id).then((pr) {
      if (!mounted) {
        pr.dispose();
        return;
      }
      _prefs = pr;
      _restorePage();
    });
    BookLinkStore.load(widget.book.id).then((b) {
      if (mounted && b != null) setState(() => _book = b);
    });
    _openInk();
  }

  Future<void> _openInk() async {
    try {
      final s = await InkStore.open(widget.book.id);
      if (!mounted) {
        s.dispose();
        return;
      }
      setState(() {
        _store = s;
        _selection = SelectionController(s.document);
      });
      if (s.document.strokeCount == 0 && s.document.items.values.every((l) => l.isEmpty)) {
        unawaited(_offerOrphans());
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// This book has no writing yet, but writing saved by an older version may
  /// be waiting unlinked: offer to bring it to this book.
  Future<void> _offerOrphans() async {
    final orphans = await InkStore.orphans(widget.library.ids);
    if (orphans.isEmpty || !mounted) return;
    String pagesText(List<int> pages) =>
        pages.length <= 8 ? pages.join('، ') : '${pages.take(8).join('، ')} …';
    final pick = await showDialog<OrphanInk>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('وُجدت كتابة سابقة غير مربوطة'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'هذه كتابة حُفظت بنسخة سابقة من التطبيق ولم تعد مربوطة بكتابها. إن كانت إحداها لهذا الكتاب فاخترها لتعود إليه:'),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in orphans)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.history_edu),
                          title: Text(
                              '${o.pages.length} صفحة مكتوب عليها · ${o.strokes} خط · ${o.items} عنصر'),
                          subtitle: Text(
                              'الصفحات: ${pagesText(o.pages)}\nآخر تعديل: ${o.modified.toLocal().toString().substring(0, 16)}'),
                          isThreeLine: true,
                          onTap: () => Navigator.pop(context, o),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ليست لهذا الكتاب')),
        ],
      ),
    );
    if (pick == null || !mounted) return;
    final old = _store;
    final oldSelection = _selection;
    setState(() {
      _store = null;
      _selection = null;
    });
    await old?.dispose();
    oldSelection?.dispose();
    final ok = await InkStore.adopt(pick.key, widget.book.id);
    if (!mounted) return;
    final book = await BookLinkStore.load(widget.book.id);
    if (mounted && book != null) setState(() => _book = book);
    await _openInk();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? 'عادت الكتابة إلى هذا الكتاب.' : 'تعذّر ربط الكتابة.')));
    }
  }

  ToolMode _lastMode = ToolMode.hand;

  void _onToolChanged() {
    // Switching tool drops the selection; other changes (colour, size,
    // fingers on the screen) keep it.
    if (_tools.mode != _lastMode) {
      _lastMode = _tools.mode;
      _selection?.clear();
    }
  }

  @override
  void dispose() {
    _tools.removeListener(_onToolChanged);
    _store?.dispose();
    _selection?.dispose();
    _tools.dispose();
    _toolbarOpen.dispose();
    _prefs?.dispose();
    super.dispose();
  }

  /// Reopen the book on the page last read (once both the viewer and the
  /// saved position are ready).
  void _restorePage() {
    final pr = _prefs;
    if (_restored || pr == null || !_viewer.isReady) return;
    _restored = true;
    if (pr.lastPage > 1 && pr.lastPage <= _viewer.pageCount) {
      _viewer.goToPage(pageNumber: pr.lastPage, duration: Duration.zero);
    }
  }

  Set<int> get _annotatedPages {
    final doc = _store?.document;
    if (doc == null) return {};
    return {
      for (final e in doc.pages.entries)
        if (e.value.isNotEmpty) e.key,
      for (final e in doc.items.entries)
        if (e.value.isNotEmpty) e.key,
    };
  }

  Future<void> _openPages() async {
    if (!_viewer.isReady) return;
    final page = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: PagesSheet(
          document: _viewer.document,
          pageCount: _viewer.pageCount,
          currentPage: _viewer.pageNumber ?? 1,
          bookmarks: _prefs?.bookmarks.toSet() ?? const {},
          annotated: _annotatedPages,
        ),
      ),
    );
    if (page != null) await _viewer.goToPage(pageNumber: page);
  }

  /// Words of a page from the PDF text layer, converted to PDF points with a
  /// top-left origin (the PDF itself counts y from the bottom).
  Future<List<WordBox>> _wordsOf(PdfPage page) =>
      _words.putIfAbsent(page.pageNumber, () async {
        final text = await page.loadStructuredText();
        final h = page.height;
        final rects = [
          for (final r in text.charRects)
            r.isEmpty ? null : Rect.fromLTRB(r.left, h - r.top, r.right, h - r.bottom),
        ];
        final words = splitWords(text.fullText, rects);
        _wordsReady[page.pageNumber] = words;
        return words;
      });

  List<Widget> _overlays(BuildContext context, Rect pageRect, PdfPage page) {
    final store = _store, selection = _selection;
    if (store == null || selection == null) return const [];
    return [
      PageInkOverlay(
        document: store.document,
        tools: _tools,
        selection: selection,
        pageNumber: page.pageNumber,
        pageWidthPt: page.width,
        pageWidthPx: pageRect.width,
        viewChanged: _viewer,
        onCreateItem: _createItem,
        onEditItem: _editItem,
        onCreateMark: _createMark,
        loadWords: () => _wordsOf(page),
      ),
    ];
  }

  Future<void> _createItem(int page, ItemKind kind, Offset pt) async {
    final isText = kind == ItemKind.text;
    final result = await _textDialog(
      title: isText ? 'نص جديد' : 'ملاحظة جديدة',
      fontSize: isText ? _tools.textSize : null,
      color: isText ? _tools.color : null,
    );
    final text = result?.text.trim() ?? '';
    if (result == null || result.delete || text.isEmpty) return;
    final size = result.fontSize ?? _tools.textSize;
    if (isText && size != _tools.textSize && _tools.mode == ToolMode.text) {
      _tools.setWidth(size); // remember the size for the next text box
    }
    final doc = _store!.document;
    doc.addItem(
      page,
      NoteItem(
        id: doc.takeStrokeId(),
        kind: kind,
        x: pt.dx,
        y: pt.dy,
        // A text box is as wide as its text, so its frame fits the words.
        w: isText ? fitTextWidth(text, size) : 0,
        text: text,
        color: isText ? _tools.color : 0xFFEF6C00,
        fontSize: size,
      ),
    );
  }

  Future<void> _createMark(int page, NoteItem draft) async {
    final doc = _store!.document;
    if (draft.style != MarkStyle.comment) {
      doc.addItem(page, draft);
      return;
    }
    final result = await _textDialog(title: 'تعليق');
    final text = result?.text.trim() ?? '';
    if (result == null || result.delete || text.isEmpty) return;
    doc.addItem(page, draft.copyWith(text: text));
  }

  /// Pins and word comments open as a note to read; text boxes open for
  /// editing.
  Future<void> _editItem(int page, NoteItem item) async {
    if (item.kind == ItemKind.pin || item.kind == ItemKind.mark) {
      return _previewItem(page, item);
    }
    return _editText(page, item);
  }

  Future<void> _editText(int page, NoteItem item) async {
    final isText = item.kind == ItemKind.text;
    final isMark = item.kind == ItemKind.mark;
    final result = await _textDialog(
      title: switch (item.kind) {
        ItemKind.pin => 'تعديل الملاحظة',
        ItemKind.mark => item.text.isEmpty ? 'إضافة تعليق' : 'تعديل التعليق',
        _ => 'النص',
      },
      initial: item.text,
      allowDelete: !isMark,
      fontSize: isText ? item.fontSize : null,
      color: isText ? item.color : null,
    );
    if (result == null) return;
    final doc = _store!.document;
    final text = result.text.trim();
    if (result.delete || (text.isEmpty && !isMark)) {
      doc.removeItem(page, item.id);
      return;
    }
    final size = result.fontSize ?? item.fontSize;
    if (text == item.text && size == item.fontSize) return;
    var next = item.copyWith(text: text, fontSize: size);
    if (isText) next = next.copyWith(w: fitTextWidth(text, size));
    if (isMark && item.style == MarkStyle.comment && text.isEmpty) {
      doc.removeItem(page, item.id); // a comment mark without its comment
      return;
    }
    doc.replaceItem(page, next);
  }

  /// A note shown for reading, with edit and delete buttons; the keyboard
  /// opens only when the user chooses to edit.
  Future<void> _previewItem(int page, NoteItem item) async {
    final isMark = item.kind == ItemKind.mark;
    final theme = Theme.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(isMark ? 'تعليق' : 'ملاحظة', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: SelectableText(
                    item.text.isEmpty ? 'لا يوجد تعليق بعد.' : item.text,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                  ),
                ),
              ),
              if (isMark) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final (style, label) in [
                    (MarkStyle.highlight, 'تظليل'),
                    (MarkStyle.underline, 'تسطير'),
                    (MarkStyle.strike, 'شطب'),
                    (MarkStyle.comment, 'تعليق فقط'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: item.style == style,
                      onSelected: (_) => Navigator.pop(context, 'style:${style.index}'),
                    ),
                ]),
              ],
              const SizedBox(height: 16),
              Row(children: [
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, 'edit'),
                  icon: const Icon(Icons.edit),
                  label: Text(item.text.isEmpty ? 'إضافة تعليق' : 'تعديل'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, 'delete'),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف'),
                ),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('إغلاق')),
              ]),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    final doc = _store!.document;
    if (action == 'edit') {
      await _editText(page, item);
    } else if (action == 'delete') {
      doc.removeItem(page, item.id);
    } else if (action.startsWith('style:')) {
      final style = MarkStyle.values[int.parse(action.substring(6))];
      doc.replaceItem(page, item.copyWith(style: style));
    }
  }

  // ---- reading mode: tap a word or a note on the page ----

  /// A tap in the hand tool: a note opens its preview, a word opens the
  /// marking menu. Returns false to leave other taps to the viewer.
  bool _onGeneralTap(BuildContext context, PdfViewerController c,
      PdfViewerGeneralTapHandlerDetails d) {
    if (_tools.drawing || d.type != PdfViewerGeneralTapType.tap) return false;
    final store = _store;
    if (store == null) return false;
    final hit = c.getPdfPageHitTestResult(d.documentPosition,
        useDocumentLayoutCoordinates: true);
    if (hit == null) return false;
    final page = hit.page;
    final pt = Offset(hit.offset.x, page.height - hit.offset.y);
    final items = store.document.itemsOf(page.pageNumber);
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if ((it.kind == ItemKind.pin || it.kind == ItemKind.mark) &&
          itemContains(it, pt)) {
        _previewItem(page.pageNumber, it);
        return true;
      }
      if (it.kind == ItemKind.tape && itemContains(it, pt)) {
        store.document.replaceItem(page.pageNumber, it.copyWith(revealed: !it.revealed));
        return true;
      }
    }
    final words = _wordsReady[page.pageNumber];
    if (words == null) {
      _wordsOf(page); // load now; the next tap is instant
      return false;
    }
    final i = wordAt(words, pt, tolerance: 2);
    if (i == null) return false;
    _wordMenu(page.pageNumber, words[i]);
    return true;
  }

  /// Highlight, underline, strike or comment the tapped word.
  Future<void> _wordMenu(int page, WordBox word) async {
    var color = 0xFFFFEB3B;
    final picked = await showModalBottomSheet<MarkStyle>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (style, icon, label) in [
                      (MarkStyle.highlight, Icons.border_color, 'تظليل'),
                      (MarkStyle.underline, Icons.format_underline, 'تسطير'),
                      (MarkStyle.strike, Icons.format_strikethrough, 'شطب'),
                      (MarkStyle.comment, Icons.comment_outlined, 'تعليق'),
                    ])
                      FilledButton.tonalIcon(
                        onPressed: () => Navigator.pop(context, style),
                        icon: Icon(icon),
                        label: Text(label),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(spacing: 10, children: [
                  for (final c in const [
                    0xFFFFEB3B, 0xFF76FF03, 0xFFFF80AB, 0xFF40C4FF,
                    0xFFD32F2F, 0xFF1565C0, 0xFF1A1A1A,
                  ])
                    GestureDetector(
                      onTap: () => setState(() => color = c),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == c ? Colors.black : Colors.black26,
                            width: color == c ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final doc = _store!.document;
    final draft = NoteItem.mark(
      id: doc.takeStrokeId(),
      lineRects: [word.rect],
      style: picked,
      color: picked == MarkStyle.comment ? 0xFFEF6C00 : color,
      quote: word.text,
    );
    await _createMark(page, draft);
  }

  // ---- export ----

  Future<void> _export() async {
    final store = _store;
    if (store == null || !_viewer.isReady) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('صورة لهذه الصفحة'),
            subtitle: const Text('PNG بدقة عالية مع كتابتك'),
            onTap: () => Navigator.pop(context, 'png'),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('PDF: الصفحات المكتوب عليها'),
            subtitle: Text('${annotatedPages(store.document).length} صفحة مع كتابتك'),
            onTap: () => Navigator.pop(context, 'pdf-marked'),
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('PDF: الكتاب كاملاً مع كتابتك'),
            onTap: () => Navigator.pop(context, 'pdf-all'),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('ملف نوتس (.nots)'),
            subtitle: const Text('الكتاب وكتابتك وربط Word والعلامات: يُفتح في نوتس على أي جهاز وتكمل عليه'),
            onTap: () => Navigator.pop(context, 'nots'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    final progress = ValueNotifier<String>('جارٍ التحضير…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Expanded(child: ValueListenableBuilder(
            valueListenable: progress,
            builder: (_, v, _) => Text(v),
          )),
        ]),
      ),
    );
    try {
      final doc = _viewer.document;
      final title = widget.book.title;
      final page = _viewer.pageNumber ?? 1;
      late final Uint8List bytes;
      late final String name;
      switch (choice) {
        case 'png':
          bytes = await pagePng(doc, store.document, page);
          name = exportFileName('$title - صفحة $page', 'png');
        case 'pdf-marked' || 'pdf-all':
          if (choice == 'pdf-marked' && annotatedPages(store.document).isEmpty) {
            throw 'لا توجد صفحات مكتوب عليها بعد.';
          }
          bytes = await exportPdf(doc, store.document,
              onlyAnnotated: choice == 'pdf-marked',
              progress: (d, t) => progress.value = 'صفحة $d من $t…');
          name = exportFileName(choice == 'pdf-marked' ? '$title - كتابتي' : title, 'pdf');
        default:
          bytes = await exportPackage(
            title: title,
            bookId: widget.book.id,
            pdf: File(widget.library.pathOf(widget.book)),
            ink: store.document,
            linkJson: await BookLinkStore.rawJson(widget.book.id),
            bookmarks: _prefs?.bookmarks ?? const [],
          );
          name = exportFileName(title, 'nots');
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      Navigator.of(context).pop();
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], title: name));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذّر التصدير: $e')));
    } finally {
      progress.dispose();
    }
  }

  void _toggleBookmark() {
    if (!_viewer.isReady) return;
    _prefs?.toggleBookmark(_viewer.pageNumber ?? 1);
    setState(() {});
  }

  /// Text entry with, for text boxes, a live font size control.
  Future<TextDialogResult?> _textDialog({
    required String title,
    String initial = '',
    bool allowDelete = false,
    double? fontSize,
    int? color,
  }) {
    final controller = TextEditingController(text: initial);
    var size = fontSize;
    final range = ToolController.textSizeRange;
    return showDialog<TextDialogResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 18)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 8,
                  style: size == null
                      ? null
                      : TextStyle(
                          fontSize: size!.clamp(12.0, 34.0),
                          color: color == null ? null : Color(color),
                        ),
                  decoration:
                      const InputDecoration(border: OutlineInputBorder()),
                ),
                if (size != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'أصغر',
                        icon: const Icon(Icons.text_decrease),
                        onPressed: () => setState(() =>
                            size = math.max(range.min, size! - 2)),
                      ),
                      Expanded(
                        child: Slider(
                          min: range.min,
                          max: range.max,
                          value: size!.clamp(range.min, range.max),
                          onChanged: (v) => setState(() => size = v),
                        ),
                      ),
                      IconButton(
                        tooltip: 'أكبر',
                        icon: const Icon(Icons.text_increase),
                        onPressed: () => setState(() =>
                            size = math.min(range.max, size! + 2)),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text('${size!.round()}', textAlign: TextAlign.center),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (allowDelete)
              TextButton(
                onPressed: () => Navigator.pop(
                    context, (text: initial, delete: true, fontSize: size)),
                child: const Text('حذف'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(context,
                    (text: controller.text, delete: false, fontSize: size)),
                child: const Text('حفظ')),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _askPage() async {
    final controller = TextEditingController();
    final count = _viewer.pageCount;
    final n = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('الانتقال إلى صفحة (1 – $count)'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, int.tryParse(controller.text)),
              child: const Text('انتقال')),
        ],
      ),
    );
    controller.dispose();
    if (n != null && n >= 1 && n <= count) {
      await _viewer.goToPage(pageNumber: n);
    }
  }

  // ---- linked book text: table of contents and search ----

  Future<void> _loadOutline(PdfDocument doc) async {
    try {
      final nodes = await doc.loadOutline();
      final out = <TocEntry>[];
      void walk(List<PdfOutlineNode> list, int level) {
        for (final n in list) {
          final page = n.dest?.pageNumber;
          if (page != null) out.add((title: n.title, level: level, pdfPage: page));
          walk(n.children, level + 1);
        }
      }

      walk(nodes, 1);
      if (mounted) setState(() => _outline = out);
    } catch (_) {
      // A PDF without a readable outline simply has no table of contents.
    }
  }

  List<TocEntry> get _tocEntries {
    final book = _book;
    return book != null ? TocPanel.fromBook(book) : _outline;
  }

  Future<void> _linkDocx() async {
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['docx'],
      dialogTitle: 'اختر ملف Word للكتاب نفسه',
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('جارٍ قراءة ملف Word…')),
        ]),
      ),
    );
    try {
      final book = await BookLinkStore.link(widget.book.id, path);
      if (!mounted) return;
      Navigator.of(context).pop();
      setState(() => _book = book);
      final pdfPages = _viewer.isReady ? _viewer.pageCount : null;
      final match = pdfPages == null || pdfPages == book.pageCount;
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(match
            ? 'تم الربط: ${book.pageCount} صفحة و${book.headings.length} عنواناً.'
            : 'تم الربط، لكن عدد الصفحات مختلف: Word ${book.pageCount} و PDF $pdfPages. قد لا تطابق أرقام الصفحات.'),
      ));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text('تعذّرت قراءة الملف: $e')));
    }
  }

  Future<void> _unlinkDocx() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء ربط ملف Word؟'),
        content: const Text('يختفي الفهرس والبحث في النص. كتابتك على الكتاب لا تتأثر.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('تراجع')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إلغاء الربط')),
        ],
      ),
    );
    if (ok != true) return;
    await BookLinkStore.unlink(widget.book.id);
    if (mounted) {
      setState(() {
        _book = null;
        _search = null;
      });
    }
  }

  Future<void> _openSearch() async {
    final book = _book;
    if (book == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('البحث يعمل في نص الكتاب: اربط ملف Word أولاً.'),
        action: SnackBarAction(label: 'ربط', onPressed: _linkDocx),
      ));
      return;
    }
    final pick = await Navigator.of(context).push<SearchPick>(MaterialPageRoute(
      builder: (_) => BookSearchPage(book: book, initialQuery: _search?.query ?? ''),
    ));
    if (pick != null && mounted) _showHit(pick);
  }

  void _showHit(SearchPick pick) {
    setState(() => _search = pick);
    final hit = pick.hits[pick.index];
    _viewer.goToPage(pageNumber: _book!.pdfPageOf(hit.page));
  }

  void _stepHit(int delta) {
    final s = _search;
    if (s == null || s.hits.isEmpty) return;
    final n = s.hits.length;
    _showHit((query: s.query, hits: s.hits, index: ((s.index + delta) % n + n) % n));
  }

  Widget _searchBanner(BuildContext context) {
    final s = _search!;
    final book = _book!;
    final hit = s.hits[s.index];
    final snip = book.snippet(hit, context: 30);
    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(children: [
          IconButton(
            tooltip: 'إغلاق البحث',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _search = null),
          ),
          Expanded(
            child: InkWell(
              onTap: _openSearch,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('«${s.query}»  ${s.index + 1} من ${s.hits.length} · صفحة ${book.pdfPageOf(hit.page)}',
                      style: theme.textTheme.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: snip.before),
                      TextSpan(text: snip.match, style: const TextStyle(fontWeight: FontWeight.bold)),
                      TextSpan(text: snip.after),
                    ]),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'السابق',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: () => _stepHit(-1),
          ),
          IconButton(
            tooltip: 'التالي',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: () => _stepHit(1),
          ),
        ]),
      ),
    );
  }

  /// Title bar text: the current section (from the linked text or the PDF
  /// outline) and the file name.
  Widget _title(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewer,
      builder: (context, _) {
        final name = widget.book.title;
        String? section;
        if (_viewer.isReady) {
          final page = _viewer.pageNumber ?? 1;
          final book = _book;
          if (book != null) {
            section = book.sectionOf(book.bookPageOf(page))?.title;
          } else {
            for (final e in _outline) {
              if (e.pdfPage > page) break;
              section = e.title;
            }
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(section ?? name,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (section != null)
              Text(name,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: ListenableBuilder(
        listenable: _viewer,
        builder: (context, _) => TocPanel(
          title: widget.book.title,
          entries: _tocEntries,
          linkedSource: _book?.source,
          currentPdfPage: _viewer.isReady ? (_viewer.pageNumber ?? 1) : 1,
          onOpen: (page) {
            Navigator.of(context).pop();
            _viewer.goToPage(pageNumber: page);
          },
          onLink: () {
            Navigator.of(context).pop();
            _linkDocx();
          },
          onUnlink: () {
            Navigator.of(context).pop();
            _unlinkDocx();
          },
        ),
      ),
      appBar: AppBar(
        toolbarHeight: 50,
        titleSpacing: 0,
        title: _title(context),
        actions: [
          IconButton(
            tooltip: 'الفهرس',
            icon: const Icon(Icons.toc),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
          IconButton(
            tooltip: 'بحث في نص الكتاب',
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
          ListenableBuilder(
            listenable: _viewer,
            builder: (context, _) {
              final marked = _viewer.isReady &&
                  (_prefs?.isBookmarked(_viewer.pageNumber ?? 1) ?? false);
              return IconButton(
                tooltip: marked ? 'إزالة علامة الصفحة' : 'وضع علامة على الصفحة',
                icon: Icon(marked ? Icons.bookmark : Icons.bookmark_border,
                    color: marked ? Colors.red : null),
                onPressed: _toggleBookmark,
              );
            },
          ),
          ListenableBuilder(
            listenable: _viewer,
            builder: (context, _) {
              if (!_viewer.isReady) return const SizedBox.shrink();
              return TextButton(
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(40, 40)),
                onPressed: _askPage,
                child: Text('${_viewer.pageNumber ?? 1}/${_viewer.pageCount}',
                    style: const TextStyle(fontSize: 13)),
              );
            },
          ),
          ListenableBuilder(
            listenable: _tools,
            builder: (context, _) => PopupMenuButton<String>(
              tooltip: 'المزيد',
              onSelected: (v) {
                switch (v) {
                  case 'pages':
                    _openPages();
                  case 'export':
                    _export();
                  case 'finger':
                    _tools.setFingerDraws(!_tools.fingerDraws);
                  case 'toolbar':
                    setState(() => _toolbarTop = !_toolbarTop);
                  case 'link':
                    _linkDocx();
                  case 'unlink':
                    _unlinkDocx();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'pages', child: Text('الصفحات والعلامات')),
                const PopupMenuItem(value: 'export', child: Text('تصدير ومشاركة')),
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: 'finger',
                  checked: _tools.fingerDraws,
                  child: const Text('الإصبع يرسم (أطفئه ليكتب القلم وحده ويحرّك الإصبعُ الصفحة)'),
                ),
                PopupMenuItem(
                  value: 'toolbar',
                  child: Text(_toolbarTop ? 'شريط الأدوات في الأسفل' : 'شريط الأدوات في الأعلى'),
                ),
                if (_book == null)
                  const PopupMenuItem(value: 'link', child: Text('ربط ملف Word (docx)'))
                else
                  const PopupMenuItem(value: 'unlink', child: Text('إلغاء ربط ملف Word')),
              ],
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('تعذّر فتح ملف الكتابة: $_error'))
          : store == null || _selection == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    Positioned.fill(
                      child: TouchNavigator(
                        tools: _tools,
                        readView: () => _viewer.isReady ? _viewer.value : null,
                        writeView: (m) {
                          if (_viewer.isReady) _viewer.value = m;
                        },
                        child: ListenableBuilder(
                          listenable: _tools,
                          builder: (context, _) => PdfViewer.file(
                            widget.library.pathOf(widget.book),
                            controller: _viewer,
                            params: PdfViewerParams(
                              // While a drawing tool is active, a finger or the
                              // pen draws; moving and zooming the page is done
                              // by [TouchNavigator] (two fingers anywhere, or one
                              // finger while a pen draws).
                              panEnabled: !_tools.drawing,
                              scaleEnabled: !_tools.drawing,
                              // Zoom out far below "fit width" (5%) and in to
                              // 1600%; vector ink stays sharp at any level.
                              sizeDelegateProvider:
                                  const PdfViewerSizeDelegateProviderLegacy(
                                minScale: 0.05,
                                maxScale: 16,
                                useAlternativeFitScaleAsMinScale: false,
                              ),
                              pageOverlaysBuilder: _overlays,
                              onGeneralTap: _onGeneralTap,
                              // Momentum scrolling: flicks carry on and add up.
                              scrollPhysics: PdfViewerParams.getScrollPhysics(context),
                              // Drag the thumb on the side to run through the
                              // book; it shows the page number.
                              viewerOverlayBuilder: (context, size, _) => [
                                PdfViewerScrollThumb(
                                  controller: _viewer,
                                  orientation: ScrollbarOrientation.left,
                                  thumbSize: const Size(46, 30),
                                  thumbBuilder: (context, size, page, c) => Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.primary,
                                      borderRadius: BorderRadius.circular(15),
                                      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text('${page ?? ''}',
                                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                                  ),
                                ),
                              ],
                              onViewerReady: (doc, _) {
                                _loadOutline(doc);
                                _restorePage();
                              },
                              onPageChanged: (n) {
                                if (n == null) return;
                                _prefs?.setLastPage(n);
                                // Ready the page's words for instant taps.
                                final pages = _viewer.document.pages;
                                for (final k in [n, n + 1]) {
                                  if (k <= pages.length) _wordsOf(pages[k - 1]);
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_search != null && _book != null)
                      Positioned(top: 0, left: 0, right: 0, child: _searchBanner(context)),
                    Positioned(
                      left: 8,
                      right: 8,
                      top: _toolbarTop ? (_search != null ? 64 : 6) : null,
                      bottom: _toolbarTop ? null : 10,
                      child: Center(
                        child: _Toolbar(
                          tools: _tools,
                          document: store.document,
                          selection: _selection!,
                          open: _toolbarOpen,
                          atTop: _toolbarTop,
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

const _modeIcons = {
  ToolMode.hand: (Icons.pan_tool_alt_outlined, 'تحريك'),
  ToolMode.pen: (Icons.edit, 'قلم'),
  ToolMode.highlighter: (Icons.border_color, 'تظليل حر'),
  ToolMode.shape: (Icons.category_outlined, 'أشكال'),
  ToolMode.text: (Icons.text_fields, 'نص'),
  ToolMode.pin: (Icons.push_pin_outlined, 'ملاحظة'),
  ToolMode.tape: (Icons.visibility_off_outlined, 'شريط لاصق للحفظ'),
  ToolMode.lasso: (Icons.gesture, 'تحديد'),
  ToolMode.eraser: (Icons.auto_fix_normal, 'ممحاة'),
};

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.tools,
    required this.document,
    required this.selection,
    required this.open,
    required this.atTop,
  });

  final ToolController tools;
  final InkDocument document;
  final SelectionController selection;
  final ValueNotifier<bool> open;
  final bool atTop;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([tools, selection, open, document]),
      builder: (context, _) {
        if (!open.value) {
          // Tools hidden: one small button shows the current tool and brings
          // the toolbar back.
          final (icon, label) = _modeIcons[tools.mode]!;
          return Align(
            alignment: atTop ? AlignmentDirectional.topEnd : AlignmentDirectional.bottomEnd,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'إظهار الأدوات ($label)',
              onPressed: () => open.value = true,
              child: Icon(icon),
            ),
          );
        }
        final options = _options(context);
        final main = _bar(context, [
          _icon(context, Icons.undo, 'تراجع', document.canUndo ? document.undo : null),
          _icon(context, Icons.redo, 'إعادة', document.canRedo ? document.redo : null),
          const SizedBox(height: 24, child: VerticalDivider()),
          for (final m in _modeIcons.keys) _mode(context, m),
          const SizedBox(height: 24, child: VerticalDivider()),
          _icon(context, atTop ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              'إخفاء الأدوات', () => open.value = false),
        ]);
        final opts = options == null ? null : _bar(context, options);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: atTop
              ? [main, if (opts != null) ...[const SizedBox(height: 6), opts]]
              : [if (opts != null) ...[opts, const SizedBox(height: 6)], main],
        );
      },
    );
  }

  /// A compact bar that scrolls sideways when it does not fit the screen.
  Widget _bar(BuildContext context, List<Widget> children) {
    return Material(
      elevation: 4,
      color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Widget _icon(BuildContext context, IconData icon, String tooltip,
      VoidCallback? onPressed, {bool selected = false}) {
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      iconSize: 21,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor:
            selected ? Theme.of(context).colorScheme.primaryContainer : null,
      ),
      onPressed: onPressed,
    );
  }

  Widget _mode(BuildContext context, ToolMode m) {
    final (icon, label) = _modeIcons[m]!;
    return _icon(context, icon, label, () => tools.setMode(m),
        selected: tools.mode == m);
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 13)),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      );

  /// Options of the current tool, or null when it has none.
  List<Widget>? _options(BuildContext context) {
    final mode = tools.mode;
    const divider = SizedBox(height: 24, child: VerticalDivider());
    if (selection.active) {
      return [
        _icon(context, Icons.delete_outline, 'حذف المحدد', selection.deleteSelected),
        _icon(context, Icons.copy_all_outlined, 'تكرار المحدد',
            selection.duplicateSelected),
        for (final c in ToolController.penColors)
          _swatch(context, c, () => selection.recolor(c), false),
      ];
    }
    if (!tools.hasStyle) return null;

    return [
      if (mode == ToolMode.pen) ...[
        for (final (kind, label) in [
          (InkTool.pen, 'حبر'),
          (InkTool.pencil, 'رصاص'),
          (InkTool.calligraphy, 'خط عربي'),
        ])
          _chip(label, tools.penKind == kind, () => tools.setPenKind(kind)),
        divider,
      ],
      if (mode == ToolMode.word) ...[
        for (final (style, label) in [
          (MarkStyle.highlight, 'تظليل'),
          (MarkStyle.underline, 'تسطير'),
          (MarkStyle.strike, 'شطب'),
          (MarkStyle.comment, 'تعليق'),
        ])
          _chip(label, tools.markStyle == style, () => tools.setMarkStyle(style)),
        divider,
      ],
      if (mode == ToolMode.shape) ...[
        for (final (kind, icon, label) in [
          (ShapeKind.line, Icons.horizontal_rule, 'خط'),
          (ShapeKind.arrow, Icons.arrow_right_alt, 'سهم'),
          (ShapeKind.rectangle, Icons.crop_square, 'مستطيل'),
          (ShapeKind.ellipse, Icons.circle_outlined, 'دائرة / قطع ناقص'),
          (ShapeKind.triangle, Icons.change_history, 'مثلث'),
        ])
          _icon(context, icon, label, () => tools.setShapeKind(kind),
              selected: tools.shapeKind == kind),
        divider,
      ],
      for (final c in tools.palette)
        _swatch(context, c, () => tools.setColor(c), tools.color == c),
      _icon(context, Icons.palette_outlined, 'لون مخصص', () async {
        final c = await showColorWheelDialog(context, Color(tools.color));
        if (c != null) tools.addCustomColor(c.toARGB32());
      }),
      if (tools.hasWidth) ...[divider, _widthControl(context)],
      if (mode == ToolMode.pen || mode == ToolMode.highlighter) ...[
        divider,
        _icon(
          context,
          Icons.auto_fix_high,
          tools.snapShapes
              ? 'استقامة تلقائية عند التوقف: مفعّلة'
              : 'استقامة تلقائية عند التوقف: متوقفة',
          () => tools.setSnapShapes(!tools.snapShapes),
          selected: tools.snapShapes,
        ),
      ],
    ];
  }

  Widget _swatch(BuildContext context, int color, VoidCallback onTap, bool selected) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(4),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  /// Width (text size for the text tool) with a live preview dot. The slider
  /// is logarithmic so very thin sizes get as much room as thick ones.
  Widget _widthControl(BuildContext context) {
    final range = tools.widthRange;
    final w = tools.width.clamp(range.min, range.max);
    final ratio = math.log(range.max / range.min);
    final t = math.log(w / range.min) / ratio;
    final dot = 4 + 18 * t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          child: Slider(
            value: t.clamp(0.0, 1.0),
            onChanged: (v) => tools.setWidth(range.min * math.exp(v * ratio)),
          ),
        ),
        SizedBox(
          width: 26,
          height: 26,
          child: Center(
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: Color(tools.color),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
