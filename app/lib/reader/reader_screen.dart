import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../book/book_link_store.dart';
import '../book/book_text.dart';
import '../export/exporter.dart';
import '../ink/ink_document.dart';
import '../ink/ink_store.dart';
import '../ink/marks.dart';
import '../ink/item_painter.dart';
import '../library/library_store.dart';
import '../ink/note_items.dart';
import '../ink/page_ink_overlay.dart';
import '../ink/ruler.dart';
import '../ink/selection.dart';
import '../ink/shapes.dart';
import '../ink/stroke.dart';
import '../ink/tool_controller.dart';
import '../ink/words.dart';
import '../ui/color_palette.dart';
import 'pages_sheet.dart';
import 'reader_prefs.dart';
import 'scrub_bar.dart';
import 'search_highlight.dart';
import 'reader_zoom.dart';
import 'search_page.dart';
import 'selection_menu.dart';
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

  /// [_search] for the pages, which draw where its hits are.
  final _searchShown = ValueNotifier<SearchPick?>(null);

  void _setSearch(SearchPick? pick) {
    setState(() => _search = pick);
    _searchShown.value = pick;
  }

  /// Last page read and bookmarks of this book.
  ReaderPrefs? _prefs;
  bool _restored = false;

  /// The colours offered in the tools and the text selection menu.
  final _palette = ColorPalette();
  static const _commentColor = 0xFF0D47A1;

  /// Full screen: the phone's own status and navigation bars hidden too.
  bool _fullScreen = false;

  void _setFullScreen(bool v) {
    setState(() => _fullScreen = v);
    SystemChrome.setEnabledSystemUIMode(
      v ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _toggleRuler() {
    if (_tools.ruler.value != null) {
      _tools.ruler.value = null;
      return;
    }
    if (!_viewer.isReady) return;
    final n = _viewer.pageNumber ?? 1;
    final page = _viewer.document.pages[n - 1];
    // About 1.5 cm wide on the screen at the current zoom, so a finger can
    // hold it in the middle and still write along either edge.
    final zoom = _viewer.currentZoom;
    _tools.ruler.value = Ruler(
      page: n,
      center: Offset(page.width / 2, page.height / 2),
      length: math.min(page.width * 0.85, 480),
      thickness: zoom > 0 ? (90 / zoom).clamp(40.0, 140.0) : 54,
    );
    // The ruler works with the writing tools.
    if (!_tools.drawing) _tools.setMode(ToolMode.pen);
  }

  /// The title bar and the tools (together, "the bars") come with a tap in
  /// the page (or on the small tab at the top) and go away by themselves a
  /// few seconds after the last use, leaving the whole screen to the page.
  bool _toolsShown = true;
  Timer? _hideTimer;
  static const _barsLinger = Duration(seconds: 5);

  void _showTools() {
    _hideTimer?.cancel();
    if (!_toolsShown) setState(() => _toolsShown = true);
    _hideTimer = Timer(_barsLinger, _hideTools);
  }

  void _hideTools() {
    _hideTimer?.cancel();
    if (mounted && _toolsShown) setState(() => _toolsShown = false);
  }

  void _toggleTools() => _toolsShown ? _hideTools() : _showTools();

  /// Word boxes already loaded, per page, for instant taps.
  final _wordsReady = <int, List<WordBox>>{};

  @override
  void initState() {
    super.initState();
    _tools.addListener(_onToolChanged);
    _palette.load();
    _showTools();
    ReaderPrefs.open(widget.book.id).then((pr) {
      if (!mounted) {
        pr.dispose();
        return;
      }
      _prefs = pr;
      _restorePage();
    });
    BookLinkStore.open(widget.book.id, widget.library.pathOf(widget.book)).then(
      (b) {
        if (mounted && b != null) _bookArrived(b);
      },
    );
    _openInk();
  }

  /// The book's text is ready. With a word map, the words of the pages come
  /// from the text (exact letters, the source's own spelling), so taps,
  /// marks, copying and search all use it.
  void _bookArrived(BookText b) {
    setState(() {
      _book = b;
      if (b.embedded) {
        _words.clear();
        _wordsReady.clear();
      }
    });
    final entry = widget.book;
    final fileTitle = entry.fileName.replaceAll(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    if (b.title.isNotEmpty && entry.title == fileTitle) {
      unawaited(widget.library.rename(entry, b.title));
    }
    if (b.embedded && b.sourceId.isNotEmpty) {
      unawaited(_offerOriginalWriting(b));
    }
  }

  /// This PDF is the linked edition of another PDF: the same pages in the
  /// same places. Writing done on the original can come along.
  Future<void> _offerOriginalWriting(BookText b) async {
    final from = b.sourceId;
    if (from == widget.book.id ||
        !await InkStore.hasWriting(from) ||
        await InkStore.hasWriting(widget.book.id) ||
        !mounted) {
      return;
    }
    final store = _store;
    if (store != null &&
        (store.document.strokeCount > 0 ||
            store.document.items.values.any((l) => l.isNotEmpty))) {
      return;
    }
    final original = widget.library.byId(from)?.title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('نقل كتابتك إلى هذه النسخة؟'),
        content: Text(
          'هذه النسخة المترابطة من الكتاب${original == null ? '' : ' «$original»'} '
          'لها الصفحات نفسها. لك كتابة وعلامات على النسخة الأصلية: '
          'تُنسخ إلى هنا في أماكنها نفسها، وتبقى الأصلية كما هي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('لا'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('نقل الكتابة'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final old = _store;
    final oldSelection = _selection;
    setState(() {
      _store = null;
      _selection = null;
    });
    await old?.dispose();
    oldSelection?.dispose();
    final copied = await InkStore.copyWriting(from, widget.book.id);
    await _openInk();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            copied ? 'نُقلت كتابتك إلى هذه النسخة.' : 'تعذّر نقل الكتابة.',
          ),
        ),
      );
    }
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
      if (s.document.strokeCount == 0 &&
          s.document.items.values.every((l) => l.isEmpty)) {
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
                'هذه كتابة حُفظت بنسخة سابقة من التطبيق ولم تعد مربوطة بكتابها. إن كانت إحداها لهذا الكتاب فاخترها لتعود إليه:',
              ),
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
                            '${o.pages.length} صفحة مكتوب عليها · ${o.strokes} خط · ${o.items} عنصر',
                          ),
                          subtitle: Text(
                            'الصفحات: ${pagesText(o.pages)}\nآخر تعديل: ${o.modified.toLocal().toString().substring(0, 16)}',
                          ),
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
            child: const Text('ليست لهذا الكتاب'),
          ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'عادت الكتابة إلى هذا الكتاب.' : 'تعذّر ربط الكتابة.',
          ),
        ),
      );
    }
  }

  ToolMode _lastMode = ToolMode.hand;

  void _onToolChanged() {
    if (_toolsShown) _showTools(); // using a tool keeps the tools in view
    // Switching tool drops the selection; other changes (colour, size,
    // fingers on the screen) keep it.
    if (_tools.mode != _lastMode) {
      _lastMode = _tools.mode;
      _selection?.clear();
    }
  }

  @override
  void dispose() {
    if (_fullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _tools.removeListener(_onToolChanged);
    _store?.dispose();
    _selection?.dispose();
    _tools.dispose();
    _hideTimer?.cancel();
    _prefs?.dispose();
    _searchShown.dispose();
    _palette.dispose();
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

  /// Words of a page in PDF points with a top-left origin: from the book's
  /// word map when it has one (the source text's exact words, each with its
  /// index in the book), else from the PDF text layer (where the PDF itself
  /// counts y from the bottom).
  Future<List<WordBox>> _wordsOf(PdfPage page) =>
      _words.putIfAbsent(page.pageNumber, () async {
        final mapped = _mappedWords(page.pageNumber);
        if (mapped != null) {
          _wordsReady[page.pageNumber] = mapped;
          return mapped;
        }
        final text = await page.loadStructuredText();
        final h = page.height;
        final rects = [
          for (final r in text.charRects)
            r.isEmpty
                ? null
                : Rect.fromLTRB(r.left, h - r.top, r.right, h - r.bottom),
        ];
        final words = splitWords(text.fullText, rects);
        _wordsReady[page.pageNumber] = words;
        return words;
      });

  /// The placed words of PDF page [pdfPage] from the word map, or null.
  List<WordBox>? _mappedWords(int pdfPage) {
    final book = _book;
    final bookPage = book?.bookPageOf(pdfPage) ?? 0;
    final l = book?.layoutOf(bookPage);
    if (book == null || l == null || l.kind == 'image' || l.kind == 'blank') {
      return null;
    }
    final text = book.pages[bookPage - 1];
    return [
      for (var i = 0; i < l.length; i++)
        if (l.rectOf(i) case final r?)
          WordBox(
            l.starts[i],
            l.ends[i],
            text.substring(l.starts[i], l.ends[i]),
            r,
            l.firstWord + i,
          ),
    ];
  }

  List<Widget> _overlays(BuildContext context, Rect pageRect, PdfPage page) {
    final store = _store, selection = _selection;
    if (store == null || selection == null) return const [];
    final book = _book;
    return [
      if (book != null && book.embedded)
        SearchHighlight(
          search: _searchShown,
          book: book,
          pdfPage: page.pageNumber,
          pageWidthPt: page.width,
        ),
      PageInkOverlay(
        // A new word source (the book's map arrived) means new words.
        key: ValueKey(book?.embedded ?? false),
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
        color: _tools.color,
        fontSize: size,
      ),
    );
  }

  Future<void> _createMark(int page, NoteItem draft) async {
    final doc = _store!.document;
    draft = _withBookWords(page, draft);
    if (draft.style != MarkStyle.comment) {
      doc.addItem(page, draft);
      return;
    }
    final result = await _textDialog(title: 'تعليق');
    final text = result?.text.trim() ?? '';
    if (result == null || result.delete || text.isEmpty) return;
    doc.addItem(page, draft.copyWith(text: text));
  }

  /// A mark on the book's words: snapped to the words it covers, quoting
  /// their exact text, and naming them by their index in the book, so the
  /// same words can be found by any app that reads the same word map.
  NoteItem _withBookWords(int pdfPage, NoteItem draft) {
    final book = _book;
    final bookPage = book?.bookPageOf(pdfPage) ?? 0;
    final l = book?.layoutOf(bookPage);
    if (book == null || l == null || draft.rects.isEmpty) return draft;
    final ids = l.wordsInRects(draft.rects);
    if (ids.isEmpty) return draft;
    final boxes = [
      for (final i in ids)
        if (l.rectOf(i) case final r?) WordBox(l.starts[i], l.ends[i], '', r),
    ];
    final snapped = NoteItem.mark(
      id: draft.id,
      lineRects: lineRects(boxes),
      style: draft.style,
      color: draft.color,
      quote: l.textOf(book.pages[bookPage - 1], ids),
      comment: draft.text,
    );
    return snapped.copyWith(
      wordFrom: l.firstWord + ids.first,
      wordTo: l.firstWord + ids.last,
    );
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

  /// A note or a word comment shown for reading, with small edit and
  /// delete buttons; the keyboard opens only when the user chooses to edit.
  Future<void> _previewItem(int page, NoteItem item) async {
    final isMark = item.kind == ItemKind.mark;
    final quote = isMark ? item.quote.trim() : '';
    final action = await _repaintAfter(
      showDialog<String>(
        context: context,
        builder: (context) {
          final theme = Theme.of(context);
          return AlertDialog(
            contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (quote.isNotEmpty) ...[
                      Text(
                        '«$quote»',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Color(item.color),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    SelectableText(
                      item.text.isEmpty ? 'لا يوجد تعليق بعد.' : item.text,
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'حذف',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => Navigator.pop(context, 'delete'),
              ),
              IconButton(
                tooltip: 'تعديل',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => Navigator.pop(context, 'edit'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إغلاق'),
              ),
            ],
          );
        },
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'edit') {
      await _editText(page, item);
    } else if (action == 'delete') {
      _store!.document.removeItem(page, item.id);
    }
  }

  // ---- reading mode: tap a word or a note on the page ----

  /// A tap in the hand tool: a note (or a commented word) shows its text, a
  /// tape strip opens or closes, and any other tap brings or hides the bars.
  /// Returns false to leave the tap to the viewer too.
  bool _onGeneralTap(
    BuildContext context,
    PdfViewerController c,
    PdfViewerGeneralTapHandlerDetails d,
  ) {
    if (_tools.drawing || d.type != PdfViewerGeneralTapType.tap) return false;
    // A tap while text is selected only lets go of the selection.
    if (c.textSelectionDelegate.hasSelectedText) return false;
    final store = _store;
    if (store == null) return false;
    final hit = c.getPdfPageHitTestResult(
      d.documentPosition,
      useDocumentLayoutCoordinates: true,
    );
    if (hit == null) {
      _toggleTools(); // a tap beside the pages
      return false;
    }
    final page = hit.page;
    final pt = Offset(hit.offset.x, page.height - hit.offset.y);
    final items = store.document.itemsOf(page.pageNumber);
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      // Only a note shows something on tap; a plain mark is left alone.
      final hasNote =
          it.kind == ItemKind.pin ||
          (it.kind == ItemKind.mark &&
              (it.text.isNotEmpty || it.style == MarkStyle.comment));
      if (hasNote && itemContains(it, pt)) {
        _previewItem(page.pageNumber, it);
        return true;
      }
      if (it.kind == ItemKind.tape && itemContains(it, pt)) {
        store.document.replaceItem(
          page.pageNumber,
          it.copyWith(revealed: !it.revealed),
        );
        return true;
      }
    }
    _toggleTools();
    return false;
  }

  /// Puts [text] on the clipboard and says so.
  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          'نُسخ: ${text.length > 60 ? '${text.substring(0, 60)}…' : text}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // ---- export ----

  Future<void> _export() async {
    final store = _store;
    if (store == null || !_viewer.isReady) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('صورة هذه الصفحة إلى المعرض'),
              subtitle: const Text('تُحفظ مباشرة في معرض الصور مع كتابتك'),
              onTap: () => Navigator.pop(context, 'gal-page'),
            ),
            ListTile(
              leading: const Icon(Icons.collections_outlined),
              title: const Text('صور الصفحات المكتوب عليها إلى المعرض'),
              subtitle: Text('${annotatedPages(store.document).length} صفحة'),
              onTap: () => Navigator.pop(context, 'gal-marked'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF: الصفحات المكتوب عليها'),
              subtitle: Text(
                '${annotatedPages(store.document).length} صفحة مع كتابتك',
              ),
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
              subtitle: const Text(
                'الكتاب وكتابتك وربط Word والعلامات: يُفتح في نوتس على أي جهاز وتكمل عليه',
              ),
              onTap: () => Navigator.pop(context, 'nots'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final progress = ValueNotifier<String>('جارٍ التحضير…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: progress,
                builder: (_, v, _) => Text(v),
              ),
            ),
          ],
        ),
      ),
    );
    try {
      final doc = _viewer.document;
      final title = widget.book.title;
      final page = _viewer.pageNumber ?? 1;
      late final Uint8List bytes;
      late final String name;
      if (choice == 'gal-page' || choice == 'gal-marked') {
        final pages = choice == 'gal-page'
            ? [page]
            : (annotatedPages(store.document).toList()..sort());
        if (pages.isEmpty) throw 'لا توجد صفحات مكتوب عليها بعد.';
        var done = 0;
        for (final n in pages) {
          progress.value = 'صفحة ${++done} من ${pages.length}…';
          final png = await pagePng(doc, store.document, n);
          final base = exportFileName(
            '$title - صفحة $n',
            'x',
          ).replaceFirst(RegExp(r'\.x$'), '');
          await Gal.putImageBytes(png, album: 'نوتس', name: base);
        }
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم حفظ ${pages.length} صورة في المعرض (ألبوم نوتس).',
            ),
          ),
        );
        return;
      }
      switch (choice) {
        case 'pdf-marked' || 'pdf-all':
          if (choice == 'pdf-marked' &&
              annotatedPages(store.document).isEmpty) {
            throw 'لا توجد صفحات مكتوب عليها بعد.';
          }
          bytes = await exportPdf(
            doc,
            store.document,
            onlyAnnotated: choice == 'pdf-marked',
            progress: (d, t) => progress.value = 'صفحة $d من $t…',
          );
          name = exportFileName(
            choice == 'pdf-marked' ? '$title - كتابتي' : title,
            'pdf',
          );
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
      if (!mounted) return;
      Navigator.of(context).pop();
      await _saveOrShare(bytes, name);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر التصدير: $e')));
    } finally {
      progress.dispose();
    }
  }

  static String _mimeOf(String fileName) {
    switch (fileName.split('.').last.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      default:
        return 'application/octet-stream';
    }
  }

  /// Finished export: save it where the user chooses (the file keeps exactly
  /// its name and extension), or share it. Sharing needs the file type
  /// stated, or Android names it ".bin".
  Future<void> _saveOrShare(Uint8List bytes, String name) async {
    final mime = _mimeOf(name);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('حفظ في الجهاز'),
              subtitle: const Text(
                'اختر المجلد، ويبقى الاسم والامتداد كما هما',
              ),
              onTap: () => Navigator.pop(context, 'save'),
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('مشاركة'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (action == 'save') {
        final saved = await FilePicker.saveFile(
          fileName: name,
          bytes: bytes,
          mimeType: mime,
          dialogTitle: 'حفظ $name',
        );
        if (saved != null) {
          messenger.showSnackBar(const SnackBar(content: Text('تم الحفظ.')));
        }
      } else {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, name: name, mimeType: mime)],
            fileNameOverrides: [name],
            title: name,
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('تعذّر ذلك: $e')));
    }
  }

  // ---- text selection menu: mark the selected words ----

  /// The menu over selected text: the colours, the ways of marking and
  /// copying. No "Select all": a whole book selected by one slip of the
  /// finger is of no use and slow to undo.
  Widget? _selectionMenu(
    BuildContext context,
    PdfViewerContextMenuBuilderParams params,
  ) {
    final delegate = params.textSelectionDelegate;
    if (!delegate.hasSelectedText) return null;

    // Copying takes the book text of the selected words, not the PDF's
    // letters.
    Future<void> copy() async {
      final text = await _selectedBookText(
        await delegate.getSelectedTextRanges(),
      );
      if (text == null) {
        await delegate.copyTextSelection();
      } else {
        _copy(text);
      }
      await delegate.clearTextSelection();
      params.dismissContextMenu();
    }

    Future<void> mark(MarkStyle style, int color) async {
      final ranges = await delegate.getSelectedTextRanges();
      final doc = _store?.document;
      if (doc == null || !_viewer.isReady) return;
      final drafts = <(int, NoteItem)>[];
      for (final r in ranges) {
        final chars = _charBoxes(r);
        if (chars.isEmpty) continue;
        drafts.add((
          r.pageNumber,
          _withBookWords(
            r.pageNumber,
            NoteItem.mark(
              id: doc.takeStrokeId(),
              lineRects: lineRects(chars),
              style: style,
              color: color,
              quote: r.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
            ),
          ),
        ));
      }
      await delegate.clearTextSelection();
      params.dismissContextMenu();
      if (drafts.isEmpty) return;
      if (style == MarkStyle.comment) {
        // One question for the whole selection, not one per page or range.
        final result = await _textDialog(title: 'تعليق');
        final text = result?.text.trim() ?? '';
        if (result == null || result.delete || text.isEmpty) return;
        for (final (page, d) in drafts) {
          doc.addItem(page, d.copyWith(text: text));
        }
        return;
      }
      for (final (page, d) in drafts) {
        applyMark(doc, page, d);
      }
      _repaintPages(); // the menu is gone: the page must come back sharp
    }

    // Copies the whole paragraph around the selection.
    Future<void> copyParagraph() async {
      final ranges = await delegate.getSelectedTextRanges();
      await delegate.clearTextSelection();
      params.dismissContextMenu();
      if (ranges.isEmpty) return;
      final r = ranges.first;
      final book = _book;
      String? text;
      final l = book?.layoutOf(book.bookPageOf(r.pageNumber));
      if (book != null && l != null) {
        final ids = l.wordsInRects(lineRects(_charBoxes(r)));
        if (ids.isNotEmpty) {
          final t = book.pages[book.bookPageOf(r.pageNumber) - 1];
          final at = l.starts[ids.first];
          final a = t.lastIndexOf('\n', at > 0 ? at - 1 : 0) + 1;
          var e = t.indexOf('\n', at);
          if (e < 0) e = t.length;
          text = t.substring(a, e).trim();
        }
      }
      if (text == null) {
        final full = r.pageText.fullText;
        final at = r.start.clamp(0, full.length);
        final a = full.lastIndexOf('\n', at > 0 ? at - 1 : 0) + 1;
        var e = full.indexOf('\n', at);
        if (e < 0) e = full.length;
        text = full.substring(a, e).trim();
      }
      if (text.isNotEmpty) _copy(text);
    }

    // A colour picked in the menu is kept for the next marks. A comment is
    // dark blue unless a colour is picked for it.
    void markWith(MarkStyle style, int? picked) {
      if (picked != null) _palette.setMarkColor(picked);
      final usual = style == MarkStyle.comment
          ? _commentColor
          : _palette.markColor;
      mark(style, picked ?? usual);
    }

    return SelectionMenu(
      palette: _palette,
      actions: [
        (label: 'تسطير', onPressed: (c) => markWith(MarkStyle.underline, c)),
        (label: 'شطب', onPressed: (c) => markWith(MarkStyle.strike, c)),
        (label: 'لون الخط', onPressed: (c) => markWith(MarkStyle.textColor, c)),
        (label: 'تعليق', onPressed: (c) => markWith(MarkStyle.comment, c)),
        (label: 'نسخ الفقرة', onPressed: (_) => copyParagraph()),
        if (delegate.isCopyAllowed) (label: 'نسخ', onPressed: (_) => copy()),
      ],
    );
  }

  /// One box per letter of a selected text range, in page points (y down).
  List<WordBox> _charBoxes(PdfPageTextRange r) {
    final h = _viewer.document.pages[r.pageNumber - 1].height;
    final chars = <WordBox>[];
    for (var i = r.start; i < r.end && i < r.pageText.charRects.length; i++) {
      final c = r.pageText.charRects[i];
      if (c.isEmpty) continue;
      chars.add(
        WordBox(
          i,
          i + 1,
          '',
          Rect.fromLTRB(c.left, h - c.top, c.right, h - c.bottom),
        ),
      );
    }
    return chars;
  }

  /// The book text of the words a PDF text selection covers, or null when
  /// the book has no word map there.
  Future<String?> _selectedBookText(List<PdfPageTextRange> ranges) async {
    final book = _book;
    if (book == null || !book.embedded || !_viewer.isReady) return null;
    final parts = <String>[];
    for (final r in ranges) {
      final bookPage = book.bookPageOf(r.pageNumber);
      final l = book.layoutOf(bookPage);
      if (l == null) return null;
      final h = _viewer.document.pages[r.pageNumber - 1].height;
      final chars = <WordBox>[];
      for (var i = r.start; i < r.end && i < r.pageText.charRects.length; i++) {
        final c = r.pageText.charRects[i];
        if (c.isEmpty) continue;
        chars.add(
          WordBox(
            i,
            i + 1,
            '',
            Rect.fromLTRB(c.left, h - c.top, c.right, h - c.bottom),
          ),
        );
      }
      final ids = l.wordsInRects(lineRects(chars));
      if (ids.isNotEmpty) parts.add(l.textOf(book.pages[bookPage - 1], ids));
    }
    return parts.isEmpty ? null : parts.join('\n');
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
    return _repaintAfter(
      showDialog<TextDialogResult>(
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
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (size != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'أصغر',
                          icon: const Icon(Icons.text_decrease),
                          onPressed: () => setState(
                            () => size = math.max(range.min, size! - 2),
                          ),
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
                          onPressed: () => setState(
                            () => size = math.min(range.max, size! + 2),
                          ),
                        ),
                        SizedBox(
                          width: 36,
                          child: Text(
                            '${size!.round()}',
                            textAlign: TextAlign.center,
                          ),
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
                  onPressed: () => Navigator.pop(context, (
                    text: initial,
                    delete: true,
                    fontSize: size,
                  )),
                  child: const Text('حذف'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, (
                  text: controller.text,
                  delete: false,
                  fontSize: size,
                )),
                child: const Text('حفظ'),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  /// [dialog], then has the viewer draw the pages again.
  ///
  /// pdfrx shows a quick, coarse picture of each page and then a sharp one
  /// of the part on screen. If the sharp one is dropped while a menu or a
  /// dialog is open (writing a comment), nothing asks for it again and the
  /// page stays blurry until it is moved. Redrawing asks for it; once more a
  /// couple of times a moment later, in case a render still running then is
  /// dropped too.
  Future<T> _repaintAfter<T>(Future<T> dialog) async {
    try {
      return await dialog;
    } finally {
      _repaintPages();
    }
  }

  void _repaintPages() {
    if (!mounted || !_viewer.isReady) return;
    _viewer.invalidate();
    for (final ms in const [400, 1200]) {
      Future.delayed(Duration(milliseconds: ms), () {
        if (mounted && _viewer.isReady) _viewer.invalidate();
      });
    }
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
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('انتقال'),
          ),
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
          if (page != null) {
            out.add((title: n.title, level: level, pdfPage: page));
          }
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
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('جارٍ قراءة ملف Word…')),
          ],
        ),
      ),
    );
    try {
      final book = await BookLinkStore.link(widget.book.id, path);
      if (!mounted) return;
      Navigator.of(context).pop();
      setState(() => _book = book);
      final pdfPages = _viewer.isReady ? _viewer.pageCount : null;
      final match = pdfPages == null || pdfPages == book.pageCount;
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            match
                ? 'تم الربط: ${book.pageCount} صفحة و${book.headings.length} عنواناً.'
                : 'تم الربط، لكن عدد الصفحات مختلف: Word ${book.pageCount} و PDF $pdfPages. قد لا تطابق أرقام الصفحات.',
          ),
        ),
      );
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
        content: const Text(
          'يختفي الفهرس والبحث في النص. كتابتك على الكتاب لا تتأثر.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إلغاء الربط'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await BookLinkStore.unlink(widget.book.id);
    if (mounted) {
      setState(() {
        _book = null;
        _search = null;
        _searchShown.value = null;
      });
    }
  }

  Future<void> _openSearch() async {
    final book = _book;
    if (book == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('البحث يعمل في نص الكتاب: اربط ملف Word أولاً.'),
          action: SnackBarAction(label: 'ربط', onPressed: _linkDocx),
        ),
      );
      return;
    }
    final pick = await Navigator.of(context).push<SearchPick>(
      MaterialPageRoute(
        builder: (_) =>
            BookSearchPage(book: book, initialQuery: _search?.query ?? ''),
      ),
    );
    if (pick != null && mounted) _showHit(pick);
  }

  /// Shows one search result: its page, and with a word map the hit itself,
  /// marked on the page and brought to the middle of the screen.
  void _showHit(SearchPick pick) {
    _setSearch(pick);
    final book = _book!;
    final hit = pick.hits[pick.index];
    final pdfPage = book.pdfPageOf(hit.page);
    final rects = book.hitRects(hit);
    if (rects.isEmpty || !_viewer.isReady || pdfPage > _viewer.pageCount) {
      _viewer.goToPage(pageNumber: pdfPage);
      return;
    }
    var box = rects.first;
    for (final r in rects.skip(1)) {
      box = box.expandToInclude(r);
    }
    final pg = _viewer.document.pages[pdfPage - 1];
    // Aim at a wide area around the hit, not at the hit itself, so the page
    // only zooms a little and the surrounding lines stay in view.
    final w = math.max(box.width, pg.width * 0.8);
    final hh = math.max(box.height, pg.height * 0.14);
    final left = (box.center.dx - w / 2)
        .clamp(0.0, math.max(0.0, pg.width - w))
        .toDouble();
    final top = (box.center.dy - hh / 2)
        .clamp(0.0, math.max(0.0, pg.height - hh))
        .toDouble();
    _viewer.goToRectInsidePage(
      pageNumber: pdfPage,
      rect: PdfRect(left, pg.height - top, left + w, pg.height - top - hh),
      anchor: PdfPageAnchor.center,
    );
  }

  void _stepHit(int delta) {
    final s = _search;
    if (s == null || s.hits.isEmpty) return;
    final n = s.hits.length;
    _showHit((
      query: s.query,
      hits: s.hits,
      index: ((s.index + delta) % n + n) % n,
    ));
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
        child: Row(
          children: [
            IconButton(
              tooltip: 'إغلاق البحث',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close),
              onPressed: () => _setSearch(null),
            ),
            Expanded(
              child: InkWell(
                onTap: _openSearch,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '«${s.query}»  ${s.index + 1} من ${s.hits.length} · صفحة ${book.pdfPageOf(hit.page)}',
                      style: theme.textTheme.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: snip.before),
                          TextSpan(
                            text: snip.match,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          TextSpan(text: snip.after),
                        ],
                      ),
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
          ],
        ),
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
            Text(
              section ?? name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (section != null)
              Text(
                name,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final appBar = AppBar(
      primary: false,
      toolbarHeight: 52,
      titleSpacing: 0,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
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
            final marked =
                _viewer.isReady &&
                (_prefs?.isBookmarked(_viewer.pageNumber ?? 1) ?? false);
            return IconButton(
              tooltip: marked ? 'إزالة علامة الصفحة' : 'وضع علامة على الصفحة',
              icon: Icon(
                marked ? Icons.bookmark : Icons.bookmark_border,
                color: marked ? Colors.red : null,
              ),
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
                minimumSize: const Size(40, 40),
              ),
              onPressed: _askPage,
              child: Text(
                '${_viewer.pageNumber ?? 1}/${_viewer.pageCount}',
                style: const TextStyle(fontSize: 13),
              ),
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
                case 'full':
                  _setFullScreen(!_fullScreen);
                case 'link':
                  _linkDocx();
                case 'unlink':
                  _unlinkDocx();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'pages',
                child: Text('الصفحات والعلامات'),
              ),
              const PopupMenuItem(
                value: 'export',
                child: Text('تصدير ومشاركة'),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: 'full',
                checked: _fullScreen,
                child: const Text('ملء الشاشة (إخفاء شريط الهاتف)'),
              ),
              CheckedPopupMenuItem(
                value: 'finger',
                checked: _tools.fingerDraws,
                child: const Text(
                  'الإصبع يرسم (أطفئه ليكتب القلم وحده ويحرّك الإصبعُ الصفحة)',
                ),
              ),
              if (_book == null)
                const PopupMenuItem(
                  value: 'link',
                  child: Text('ربط ملف Word (docx)'),
                )
              else if (!_book!.embedded)
                // A word map is part of the PDF itself: nothing to unlink.
                const PopupMenuItem(
                  value: 'unlink',
                  child: Text('إلغاء ربط ملف Word'),
                ),
            ],
          ),
        ),
      ],
    );
    return Scaffold(
      key: _scaffoldKey,
      // The keyboard (writing a comment or a note) must not squeeze the
      // page: that re-lays it out and can leave it drawn blurry. Dialogs
      // make room for the keyboard themselves.
      resizeToAvoidBottomInset: false,
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
          embedded: _book?.embedded ?? false,
          onUnlink: (_book?.embedded ?? false)
              ? null
              : () {
                  Navigator.of(context).pop();
                  _unlinkDocx();
                },
        ),
      ),
      body: _error != null
          ? Center(child: Text('تعذّر فتح ملف الكتابة: $_error'))
          : store == null || _selection == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Positioned.fill(child: _viewerArea()),
                Positioned(
                  left: 0,
                  top: MediaQuery.paddingOf(context).top + 64,
                  bottom: 8,
                  width: 60,
                  child: ScrubBar(controller: _viewer, shown: _toolsShown),
                ),
                // While the bars are away: a small tab at the top, showing
                // the tool in use, brings them back (as does a tap on the
                // page with the hand tool).
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 2,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: IgnorePointer(
                      ignoring: _toolsShown,
                      child: AnimatedOpacity(
                        opacity: _toolsShown ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: _barsTab(context),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !_toolsShown,
                    child: AnimatedSlide(
                      offset: _toolsShown ? Offset.zero : const Offset(0, -1),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: _toolsShown ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Listener(
                          // Any touch on the bars keeps them in view.
                          onPointerDown: (_) => _showTools(),
                          onPointerMove: (_) => _showTools(),
                          child: _bars(context, store, appBar),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Title bar (under the phone's status bar), the search result being
  /// shown, and the tools, one under the other.
  Widget _bars(BuildContext context, InkStore store, PreferredSizeWidget bar) {
    final theme = Theme.of(context);
    final pad = MediaQuery.paddingOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 2,
          color: theme.colorScheme.surfaceContainer,
          child: Padding(
            padding: EdgeInsets.only(
              top: pad.top,
              left: pad.left,
              right: pad.right,
            ),
            child: SizedBox(height: 52, child: bar),
          ),
        ),
        if (_search != null && _book != null) _searchBanner(context),
        Padding(
          padding: EdgeInsets.fromLTRB(pad.left + 8, 6, pad.right + 8, 0),
          child: Center(child: _toolbar(store)),
        ),
      ],
    );
  }

  /// The tab that brings the bars back.
  Widget _barsTab(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _tools,
      builder: (context, _) => Material(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
        elevation: 2,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: _showTools,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _modeIcons[_tools.mode]?.$1 ?? Icons.pan_tool_alt_outlined,
                  size: 18,
                  color: _tools.drawing ? Color(_tools.color) : null,
                ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(InkStore store) => _Toolbar(
    tools: _tools,
    document: store.document,
    selection: _selection!,
    palette: _palette,
    onToggleRuler: _toggleRuler,
  );

  Widget _viewerArea() {
    return TouchNavigator(
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
            // While a drawing tool is active, a finger or the pen draws;
            // moving and zooming the page is done by [TouchNavigator] (two
            // fingers anywhere, or one finger when finger drawing is off).
            panEnabled: !_tools.drawing,
            scaleEnabled: !_tools.drawing,
            // Zoom out until a whole page shows, and in to 1600%; vector
            // ink stays sharp at any level.
            sizeDelegateProvider: const ReaderZoom(),
            pageOverlaysBuilder: _overlays,
            onGeneralTap: _onGeneralTap,
            buildContextMenu: _selectionMenu,
            // Momentum scrolling: flicks carry on.
            scrollPhysics: PdfViewerParams.getScrollPhysics(context),
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
    );
  }
}

const _modeIcons = {
  ToolMode.hand: (Icons.pan_tool_alt_outlined, 'تحريك'),
  ToolMode.pen: (Icons.edit, 'قلم'),
  ToolMode.highlighter: (Icons.border_color, 'تظليل'),
  ToolMode.shape: (Icons.category_outlined, 'أشكال'),
  ToolMode.text: (Icons.text_fields, 'نص'),
  ToolMode.pin: (Icons.push_pin_outlined, 'ملاحظة'),
  ToolMode.lasso: (Icons.gesture, 'تحديد'),
  ToolMode.eraser: (Icons.auto_fix_normal, 'ممحاة'),
};

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.tools,
    required this.document,
    required this.selection,
    required this.palette,
    required this.onToggleRuler,
  });

  final VoidCallback onToggleRuler;

  final ToolController tools;
  final InkDocument document;
  final SelectionController selection;
  final ColorPalette palette;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([tools, selection, document]),
      builder: (context, _) {
        final options = _options(context);
        // Every tool is visible at once: the row wraps to a second line on
        // narrow screens instead of hiding tools off to the side.
        final main = _bar(context, wrap: true, [
          _icon(
            context,
            Icons.undo,
            'تراجع',
            document.canUndo ? document.undo : null,
          ),
          _icon(
            context,
            Icons.redo,
            'إعادة',
            document.canRedo ? document.redo : null,
          ),
          const SizedBox(height: 24, child: VerticalDivider()),
          for (final m in _modeIcons.keys) _mode(context, m),
          ValueListenableBuilder(
            valueListenable: tools.ruler,
            builder: (context, r, _) => _icon(
              context,
              Icons.straighten,
              'المسطرة',
              onToggleRuler,
              selected: r != null,
            ),
          ),
        ]);
        final opts = options == null ? null : _bar(context, options);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              main,
              if (opts != null) ...[const SizedBox(height: 4), opts],
            ],
          ),
        );
      },
    );
  }

  /// A compact bar that scrolls sideways when it does not fit the screen.
  /// A compact bar. Option bars scroll sideways; the main bar wraps.
  Widget _bar(
    BuildContext context,
    List<Widget> children, {
    bool wrap = false,
  }) {
    return Material(
      elevation: 4,
      color: Theme.of(context).colorScheme.surfaceContainerHigh
          .withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: wrap
            ? Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: children,
              )
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(mainAxisSize: MainAxisSize.min, children: children),
              ),
      ),
    );
  }

  Widget _icon(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    bool selected = false,
  }) {
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      iconSize: 21,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
      ),
      onPressed: onPressed,
    );
  }

  Widget _mode(BuildContext context, ToolMode m) {
    final (icon, label) = _modeIcons[m]!;
    return _icon(
      context,
      icon,
      label,
      () => tools.setMode(m),
      selected: tools.mode == m,
    );
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
        _icon(
          context,
          Icons.delete_outline,
          'حذف المحدد',
          selection.deleteSelected,
        ),
        _icon(
          context,
          Icons.copy_all_outlined,
          'تكرار المحدد',
          selection.duplicateSelected,
        ),
        _colorButton(
          context,
          selection.currentColor ?? tools.color,
          (c) => selection.recolor(c),
        ),
      ];
    }
    if (mode == ToolMode.eraser) {
      return [
        _chip(
          'خط كامل',
          !tools.eraserPartial,
          () => tools.setEraserPartial(false),
        ),
        _chip(
          'ممحاة عادية',
          tools.eraserPartial,
          () => tools.setEraserPartial(true),
        ),
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
      if (mode == ToolMode.shape) ...[
        for (final (kind, icon, label) in [
          (ShapeKind.line, Icons.horizontal_rule, 'خط'),
          (ShapeKind.arrow, Icons.arrow_right_alt, 'سهم'),
          (ShapeKind.ellipse, Icons.circle_outlined, 'دائرة / قطع ناقص'),
        ])
          _icon(
            context,
            icon,
            label,
            () => tools.setShapeKind(kind),
            selected: tools.shapeKind == kind,
          ),
        divider,
      ],
      _colorButton(context, tools.color, tools.setColor),
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

  /// One colour circle: it shows the current colour and opens the list of
  /// colours to change it.
  Widget _colorButton(
    BuildContext context,
    int color,
    void Function(int) onPicked,
  ) {
    return Tooltip(
      message: 'اللون',
      child: GestureDetector(
        onTap: () async {
          final c = await showColorListDialog(context, palette, color);
          if (c != null) onPicked(c);
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color(color),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline,
              width: 2,
            ),
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
