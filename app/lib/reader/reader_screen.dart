import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../book/book_link_store.dart';
import '../book/book_text.dart';
import '../ink/ink_store.dart';
import '../ink/note_items.dart';
import '../ink/page_ink_overlay.dart';
import '../ink/selection.dart';
import '../ink/shapes.dart';
import '../ink/stroke.dart';
import '../ink/tool_controller.dart';
import '../ink/words.dart';
import '../ui/color_wheel.dart';
import 'search_page.dart';
import 'toc_panel.dart';
import 'touch_navigator.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.pdfPath});

  final String pdfPath;

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

  @override
  void initState() {
    super.initState();
    _tools.addListener(_onToolChanged);
    BookLinkStore.load(widget.pdfPath).then((b) {
      if (mounted && b != null) setState(() => _book = b);
    });
    InkStore.open(widget.pdfPath).then((s) {
      if (!mounted) {
        s.dispose();
        return;
      }
      setState(() {
        _store = s;
        _selection = SelectionController(s.document);
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
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
    super.dispose();
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
        return splitWords(text.fullText, rects);
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
        zoom: () => _viewer.isReady ? _viewer.currentZoom : 1.0,
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
    if (isText && size != _tools.textSize) {
      // Remember the size for the next text box.
      final mode = _tools.mode;
      if (mode == ToolMode.text) _tools.setWidth(size);
    }
    final doc = _store!.document;
    doc.addItem(
      page,
      NoteItem(
        id: doc.takeStrokeId(),
        kind: kind,
        x: pt.dx,
        y: pt.dy,
        w: isText ? NoteItem.defaultTextWidth : 0,
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
    final result = await _textDialog(title: 'تعليق على «${_short(draft.quote)}»');
    final text = result?.text.trim() ?? '';
    if (result == null || result.delete || text.isEmpty) return;
    doc.addItem(page, draft.copyWith(text: text));
  }

  static String _short(String s) => s.length <= 40 ? s : '${s.substring(0, 40)}…';

  Future<void> _editItem(int page, NoteItem item) async {
    final isText = item.kind == ItemKind.text;
    final isMark = item.kind == ItemKind.mark;
    final result = await _textDialog(
      title: switch (item.kind) {
        ItemKind.pin => 'الملاحظة',
        ItemKind.mark => 'تعليق على «${_short(item.quote)}»',
        _ => 'النص',
      },
      initial: item.text,
      allowDelete: true,
      fontSize: isText ? item.fontSize : null,
      color: isText ? item.color : null,
    );
    if (result == null) return;
    final doc = _store!.document;
    final text = result.text.trim();
    if (result.delete) {
      doc.removeItem(page, item.id);
    } else if (text.isEmpty && !isMark) {
      doc.removeItem(page, item.id);
    } else {
      final size = result.fontSize ?? item.fontSize;
      if (text != item.text || size != item.fontSize) {
        // Keep the text box proportions when its size changes.
        final w = isText && size != item.fontSize
            ? item.w * size / item.fontSize
            : item.w;
        doc.replaceItem(page, item.copyWith(text: text, fontSize: size, w: w));
      }
    }
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
      final book = await BookLinkStore.link(widget.pdfPath, path);
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
    await BookLinkStore.unlink(widget.pdfPath);
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
        final name = p.basenameWithoutExtension(widget.pdfPath);
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
          title: p.basenameWithoutExtension(widget.pdfPath),
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
              if (!_viewer.isReady) return const SizedBox.shrink();
              return TextButton(
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(40, 40)),
                onPressed: _askPage,
                child: Text(
                    '${_viewer.pageNumber ?? 1}/${_viewer.pageCount}\n${(_viewer.currentZoom * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, height: 1.2)),
              );
            },
          ),
          if (store != null)
            ListenableBuilder(
              listenable: store.document,
              builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'تراجع',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.undo),
                  onPressed: store.document.canUndo ? store.document.undo : null,
                ),
                IconButton(
                  tooltip: 'إعادة',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.redo),
                  onPressed: store.document.canRedo ? store.document.redo : null,
                ),
              ]),
            ),
          ListenableBuilder(
            listenable: _tools,
            builder: (context, _) => PopupMenuButton<String>(
              tooltip: 'المزيد',
              onSelected: (v) {
                switch (v) {
                  case 'finger':
                    _tools.setFingerDraws(!_tools.fingerDraws);
                  case 'link':
                    _linkDocx();
                  case 'unlink':
                    _unlinkDocx();
                }
              },
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: 'finger',
                  checked: _tools.fingerDraws,
                  child: const Text('الإصبع يرسم (أطفئه ليحرّك الإصبعُ الصفحةَ عند الكتابة بالقلم)'),
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
                            widget.pdfPath,
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
                              onViewerReady: (doc, _) => _loadOutline(doc),
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
                      bottom: 10,
                      child: Center(
                        child: _Toolbar(
                          tools: _tools,
                          viewer: _viewer,
                          selection: _selection!,
                          open: _toolbarOpen,
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
  ToolMode.word: (Icons.highlight_alt, 'على الكلمات: تظليل وتسطير وتعليق'),
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
    required this.viewer,
    required this.selection,
    required this.open,
  });

  final ToolController tools;
  final PdfViewerController viewer;
  final SelectionController selection;
  final ValueNotifier<bool> open;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([tools, selection, open]),
      builder: (context, _) {
        if (!open.value) {
          // Tools hidden: one small button shows the current tool and brings
          // the toolbar back.
          final (icon, label) = _modeIcons[tools.mode]!;
          return Align(
            alignment: AlignmentDirectional.bottomEnd,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'إظهار الأدوات ($label)',
              onPressed: () => open.value = true,
              child: Icon(icon),
            ),
          );
        }
        final options = _options(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (options != null) ...[
              _bar(context, options),
              const SizedBox(height: 6),
            ],
            _bar(context, [
              for (final m in _modeIcons.keys) _mode(context, m),
              const SizedBox(height: 24, child: VerticalDivider()),
              _icon(context, Icons.zoom_out, 'تصغير', () => viewer.zoomDown()),
              _icon(context, Icons.zoom_in, 'تكبير', () => viewer.zoomUp()),
              _icon(context, Icons.keyboard_arrow_down, 'إخفاء الأدوات',
                  () => open.value = false),
            ]),
          ],
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
      VoidCallback onPressed, {bool selected = false}) {
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
