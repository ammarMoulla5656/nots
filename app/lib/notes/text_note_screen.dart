import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../export/doc_export.dart';
import '../export/share_file.dart';
import '../ink/ink_store.dart';
import '../ink/selection.dart';
import '../ink/tool_controller.dart';
import '../library/home_sheets.dart' show ActionRow, ActionRows;
import '../library/library_store.dart';
import '../library/collections_ui.dart' show askName;
import '../reader/reader_chrome.dart';
import '../reader/reader_sheets.dart' show TocSheet;
import '../ink/page_ink_overlay.dart';
import '../ui/app_settings.dart';
import '../ui/brand_widgets.dart';
import '../ui/color_palette.dart';
import '../ui/theme.dart';
import 'text_note.dart';

/// The width of the page in points (A4): the drawing's coordinates and the
/// text's width are both in these.
const _pageW = 595.0;
const _pageH = 842.0;
const _lineH = 32.0; // a ruled line, and the height of a line of text

/// A text note: typing with fonts, sizes, colours, headings and lists on a
/// long ruled page, and drawing over it. One button changes between the two.
class TextNoteScreen extends StatefulWidget {
  const TextNoteScreen({super.key, required this.library, required this.book});

  final LibraryStore library;
  final BookEntry book;

  @override
  State<TextNoteScreen> createState() => _TextNoteScreenState();
}

class _TextNoteScreenState extends State<TextNoteScreen> {
  QuillController? _q;
  final _focus = FocusNode();
  final _editorKey = GlobalKey<QuillEditorState>();
  final _pageKey = GlobalKey();
  final _vScroll = ScrollController();

  final _tools = ToolController(fingerDraws: AppSettings.instance.fingerDraws);
  final _palette = ColorPalette();
  InkStore? _store;
  SelectionController? _selection;

  /// Fires when the zoom changes (the ink overlay listens).
  final _view = ValueNotifier<int>(0);

  bool _drawing = false;
  bool _options = false;
  double _zoom = 1;
  double _contentH = _pageH;
  Timer? _saveTimer;
  StreamSubscription<dynamic>? _changes;
  Object? _error;

  late String _title = widget.book.title;

  @override
  void initState() {
    super.initState();
    unawaited(_palette.load());
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final ops = await TextNoteStore.read(widget.book.id);
      final store = await InkStore.open(widget.book.id);
      if (!mounted) {
        await store.dispose();
        return;
      }
      final q = QuillController(
        document: Document.fromJson(ops),
        selection: const TextSelection.collapsed(offset: 0),
      );
      _changes = q.changes.listen((_) => _scheduleSave());
      setState(() {
        _q = q;
        _store = store;
        _selection = SelectionController(store.document);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _saveText);
  }

  Future<void> _saveText() async {
    _saveTimer?.cancel();
    final q = _q;
    if (q == null) return;
    await TextNoteStore.write(widget.book.id, q.document.toDelta().toJson());
    TextNoteStore.forgetPreview(widget.book.id);
  }

  /// Everything to disk: the text and the drawing.
  Future<void> _flush() async {
    await _saveText();
    await _store?.flush();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_changes?.cancel());
    final q = _q;
    if (q != null) {
      unawaited(
        TextNoteStore.write(widget.book.id, q.document.toDelta().toJson()),
      );
    }
    unawaited(_store?.dispose());
    q?.dispose();
    _selection?.dispose();
    _tools.dispose();
    _palette.dispose();
    _view.dispose();
    _focus.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  // ---- modes

  void _setDrawing(bool on) {
    setState(() {
      _drawing = on;
      _options = false;
      if (on) {
        _focus.unfocus();
        _tools.setMode(ToolMode.pen);
      } else {
        _tools.setMode(ToolMode.hand);
      }
    });
  }

  void _zoomBy(double factor) {
    setState(() => _zoom = (_zoom * factor).clamp(0.6, 3.0));
    _view.value++;
  }

  bool get _lines => textNoteHasLines(widget.book);

  Future<void> _toggleLines() => widget.library.markNote(
    widget.book,
    template: '$textPaperPrefix${_lines ? 'plain' : 'lined'}',
  );

  Future<void> _rename() async {
    final n = await askName(context, title: 'اسم الملف', initial: _title);
    if (n == null) return;
    await widget.library.rename(widget.book, n);
    if (mounted) setState(() => _title = n);
  }

  // ---- contents

  Future<void> _openContents() async {
    final q = _q;
    if (q == null) return;
    final heads = headingsOf(q.document);
    final here = q.selection.baseOffset;
    final offset = await showNotsSheet<int>(
      context,
      builder: (_) => TocSheet(
        entries: [
          for (final h in heads)
            (title: h.title, level: h.level, pdfPage: h.offset),
        ],
        currentPdfPage: here,
        onLink: () {},
        showPages: false,
        emptyMessage: 'لا توجد عناوين بعد.\n\nحدّد سطراً واختر «عنوان 1» أو «عنوان 2» أو «عنوان 3» من شريط الأدوات، فيظهر هنا ويمكنك الانتقال إليه.',
      ),
    );
    if (offset == null || !mounted) return;
    q.updateSelection(
      TextSelection.collapsed(offset: offset),
      ChangeSource.local,
    );
    // Bring the heading into view.
    final r = _editorKey
        .currentState
        ?.editableTextKey
        .currentState
        ?.renderEditor
        .getLocalRectForCaret(TextPosition(offset: offset));
    if (r != null && _vScroll.hasClients) {
      final box = context.size?.width ?? _pageW;
      final scale = box / _pageW * _zoom;
      _vScroll.animateTo(
        (r.top * scale - 12).clamp(0.0, _vScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  // ---- export

  Future<void> _export() async {
    final q = _q;
    if (q == null) return;
    await _flush();
    if (!mounted) return;
    final kind = await showNotsSheet<String>(
      context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('تصدير'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: ActionRows(
                rows: [
                  ActionRow(
                    Icons.description_outlined,
                    'Word (docx)',
                    () => Navigator.pop(context, 'docx'),
                    subtitle:
                        'النص بخطوطه وألوانه وعناوينه وفهرسه، قابل للتعديل',
                  ),
                  ActionRow(
                    Icons.article_outlined,
                    'RTF',
                    () => Navigator.pop(context, 'rtf'),
                    subtitle: 'يفتح في Word وأغلب المحررات',
                  ),
                  ActionRow(
                    Icons.picture_as_pdf_outlined,
                    'PDF',
                    () => Navigator.pop(context, 'pdf'),
                    subtitle: 'للطباعة والإرسال، ومعه الرسم',
                  ),
                  ActionRow(
                    Icons.text_snippet_outlined,
                    'قلم المصدر (.nots)',
                    () => Navigator.pop(context, 'nots'),
                    subtitle: 'كل شيء كما هو، ومعه الرسم، ليُفتح في التطبيق',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    final ops = q.document.toDelta().toJson();
    final messenger = ScaffoldMessenger.of(context);
    // The file is made first (it may take a moment), then handed over.
    try {
      final Uint8List bytes;
      final String name;
      switch (kind) {
        case 'docx':
          bytes = writeDocx(ops, title: _title);
          name = '$_title.docx';
        case 'rtf':
          bytes = writeRtf(ops, title: _title);
          name = '$_title.rtf';
        case 'pdf':
          bytes = await _pdf();
          name = '$_title.pdf';
        default:
          bytes = await textNotePackage(
            title: _title,
            ops: ops,
            ink: _store!.document,
          );
          name = '$_title.nots';
      }
      if (!mounted) return;
      await shareBytes(context, bytes, name);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('تعذّر التصدير: $e')));
    }
  }

  /// The page as it is on the screen, text and drawing, cut into A4 sheets.
  Future<Uint8List> _pdf() async {
    _focus.unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final boundary =
        _pageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    const ratio = 2.5;
    final image = await boundary.toImage(pixelRatio: ratio);
    try {
      return await cutPageImage(
        image,
        pageWidthPt: _pageW,
        pageHeightPt: _pageH,
        pixelRatio: ratio,
      );
    } finally {
      image.dispose();
    }
  }

  // ---- the screen

  Widget _toolbar(QuillController q) {
    return Material(
      color: Brand.surface,
      child: QuillSimpleToolbar(
        controller: q,
        config: QuillSimpleToolbarConfig(
          // One row that slides sideways: nothing goes off the screen.
          multiRowsDisplay: false,
          showSearchButton: false,
          showSubscript: false,
          showSuperscript: false,
          showInlineCode: false,
          showCodeBlock: false,
          showQuote: false,
          showLink: false,
          showSmallButton: false,
          showListCheck: false,
          showLineHeightButton: false,
          buttonOptions: const QuillSimpleToolbarButtonOptions(
            fontFamily: QuillToolbarFontFamilyButtonOptions(
              items: {
                'منى': 'Muna',
                'أميري': 'Amiri',
                'شهرزاد': 'Scheherazade',
                'كوفي': 'Kufi',
              },
            ),
            fontSize: QuillToolbarFontSizeButtonOptions(
              items: {
                '12': '12',
                '14': '14',
                '16': '16',
                '18': '18',
                '20': '20',
                '24': '24',
                '28': '28',
                '36': '36',
                '48': '48',
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _drawBar() {
    return ListenableBuilder(
      listenable: Listenable.merge([_tools, _store!.document]),
      builder: (context, _) {
        final doc = _store!.document;
        Widget tool(IconData icon, String tip, ToolMode m) => BarButton(
          icon: icon,
          tooltip: tip,
          selected: _tools.mode == m,
          onPressed: () {
            // The tool again: its colours and size.
            if (_tools.mode == m) {
              setState(() => _options = !_options);
            } else {
              _tools.setMode(m);
              setState(() => _options = false);
            }
          },
        );
        return Material(
          color: Brand.surface,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                tool(Icons.edit_outlined, 'قلم', ToolMode.pen),
                tool(
                  Icons.border_color_outlined,
                  'تظليل',
                  ToolMode.highlighter,
                ),
                tool(Icons.auto_fix_normal, 'ممحاة', ToolMode.eraser),
                tool(Icons.gesture, 'تحديد', ToolMode.lasso),
                tool(Icons.category_outlined, 'أشكال', ToolMode.shape),
                Container(width: 1, height: 22, color: Brand.line),
                BarButton(
                  icon: Icons.undo,
                  tooltip: 'تراجع',
                  color: Brand.gold,
                  onPressed: doc.canUndo ? doc.undo : null,
                ),
                BarButton(
                  icon: Icons.redo,
                  tooltip: 'إعادة',
                  color: Brand.gold,
                  onPressed: doc.canRedo ? doc.redo : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The ruled lines behind the text.
  Widget _paper() => CustomPaint(painter: _LinesPainter(_lines));

  Widget _page(QuillController q, double screenW, double viewH) {
    final scale = screenW / _pageW * _zoom;
    // The page is at least as tall as the screen: no bare desk under it.
    final minH = math.max(_pageH, viewH / scale);
    final w = math.max(_pageW * scale, screenW);
    final editor = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minH),
      child: IgnorePointer(
        ignoring: _drawing,
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: QuillEditor(
            key: _editorKey,
            controller: q,
            focusNode: _focus,
            scrollController: ScrollController(),
            config: QuillEditorConfig(
              scrollable: false,
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
              placeholder: 'اكتب هنا…',
              customStyles: DefaultStyles(
                paragraph: DefaultTextBlockStyle(
                  const TextStyle(
                    fontFamily: 'Muna',
                    fontSize: 20,
                    height: 1.6,
                    color: Colors.black87,
                  ),
                  HorizontalSpacing.zero,
                  VerticalSpacing.zero,
                  VerticalSpacing.zero,
                  null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final page = SizedBox(
      width: _pageW,
      child: SizeChangedLayoutNotifier(
        child: RepaintBoundary(
          key: _pageKey,
          child: ColoredBox(
            color: Colors.white,
            child: Stack(
              children: [
                Positioned.fill(child: _paper()),
                editor,
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_drawing,
                    child: PageInkOverlay(
                      key: const ValueKey('ink'),
                      document: _store!.document,
                      tools: _tools,
                      selection: _selection!,
                      pageNumber: 1,
                      pageWidthPt: _pageW,
                      pageWidthPx: _pageW,
                      viewChanged: _view,
                      onCreateItem: (_, _, _) async {},
                      onEditItem: (_, _) async {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final scaled = SizedBox(
      width: w,
      height: _contentH * scale,
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minWidth: _pageW,
        maxWidth: _pageW,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topCenter,
          child: page,
        ),
      ),
    );
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final h = _pageKey.currentContext?.size?.height;
          if (h != null && (h - _contentH).abs() > 1 && mounted) {
            setState(() => _contentH = h);
          }
        });
        return false;
      },
      child: SingleChildScrollView(
        controller: _vScroll,
        // While drawing with a finger the page stays still.
        physics: _drawing && _tools.fingerDraws
            ? const NeverScrollableScrollPhysics()
            : null,
        child: Column(
          children: [
            w > screenW
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: scaled,
                  )
                : scaled,
            const SizedBox(height: 260),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _q;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _flush();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: Brand.desk,
        appBar: AppBar(
          title: GestureDetector(
            onTap: _rename,
            child: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          actions: [
            IconButton(
              tooltip: _drawing ? 'وضع الكتابة' : 'وضع الرسم',
              icon: Icon(
                _drawing ? Icons.keyboard_alt_outlined : Icons.brush_outlined,
              ),
              onPressed: q == null ? null : () => _setDrawing(!_drawing),
            ),
            IconButton(
              tooltip: 'الفهرس',
              icon: const Icon(Icons.format_list_bulleted),
              onPressed: q == null ? null : _openContents,
            ),
            IconButton(
              tooltip: 'تصغير',
              icon: const Icon(Icons.zoom_out),
              onPressed: () => _zoomBy(1 / 1.15),
            ),
            IconButton(
              tooltip: 'تكبير',
              icon: const Icon(Icons.zoom_in),
              onPressed: () => _zoomBy(1.15),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'export') _export();
                if (v == 'lines') _toggleLines();
                if (v == 'rename') _rename();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'export',
                  child: Text('تصدير ومشاركة'),
                ),
                PopupMenuItem(
                  value: 'lines',
                  child: Text(_lines ? 'إخفاء الخطوط' : 'إظهار الخطوط'),
                ),
                const PopupMenuItem(
                  value: 'rename',
                  child: Text('إعادة التسمية'),
                ),
              ],
            ),
          ],
        ),
        body: _error != null
            ? Center(child: Text('تعذّر فتح الملف: $_error'))
            : q == null || _store == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _drawing ? _drawBar() : _toolbar(q),
                  if (_drawing && _options)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                      child: PanelFrame(
                        child: ToolOptions(
                          tools: _tools,
                          palette: _palette,
                          fingerDraws: _tools.fingerDraws,
                          onFinger: AppSettings.instance.setFingerDraws,
                          onColor: () => setState(() => _options = false),
                        ),
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) =>
                          _page(q, box.maxWidth, box.maxHeight),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The lines of the paper, one for each line of text.
class _LinesPainter extends CustomPainter {
  const _LinesPainter(this.on);

  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    if (!on) return;
    final paint = Paint()
      ..color = const Color(0xFFD6DEEA)
      ..strokeWidth = 0.8;
    // The first line of text sits a little under the top padding.
    for (var y = 20 + _lineH; y < size.height; y += _lineH) {
      canvas.drawLine(Offset(16, y), Offset(size.width - 16, y), paint);
    }
  }

  @override
  bool shouldRepaint(_LinesPainter old) => old.on != on;
}
