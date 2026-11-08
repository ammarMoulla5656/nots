import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../book/book_link_store.dart';
import '../book/book_text.dart';
import '../export/exporter.dart';
import '../ink/image_items.dart';
import '../ink/ink_store.dart';
import '../ink/marks.dart';
import '../ink/item_painter.dart';
import '../library/library_store.dart';
import '../notes/note_pdf.dart';
import '../notes/paper.dart';
import '../notes/paper_templates.dart';
import '../library/home_sheets.dart' show NewPaperSheet;
import '../sync/conflicts.dart';
import '../ink/note_items.dart';
import '../ink/page_ink_overlay.dart';
import '../ink/ruler.dart';
import '../ink/selection.dart';
import '../ink/tool_controller.dart';
import '../ink/words.dart';
import '../library/home_sheets.dart' show ActionRow, ActionRows, HistorySheet;
import '../library/book_widgets.dart' show ReadProgress;
import '../ui/app_settings.dart';
import '../ui/brand_widgets.dart';
import '../ui/speed_log.dart';
import '../ui/color_palette.dart';
import '../ui/theme.dart';
import 'conflict_bar.dart';
import 'page_map.dart';
import 'pages_sheet.dart';
import 'reader_chrome.dart';
import 'reader_prefs.dart';
import 'reader_zoom.dart';
import 'reader_sheets.dart';
import 'tool_layout.dart';
import 'scrub_bar.dart';
import 'search_highlight.dart';
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

/// Result of the text sheet. [fontSize] is null for pins and comments.
typedef TextDialogResult = TextEntry;

/// The Masdar app, which the reader can open.
const masdarPackage = 'iq.alhikmeh.the_source';

class _ReaderScreenState extends State<ReaderScreen> {
  late final _tools = ToolController(
    fingerDraws: AppSettings.instance.fingerDraws,
  );
  final _layout = ToolLayout.instance;
  ReaderPop _pop = ReaderPop.none;
  double _viewWidth = 400;
  final _viewer = PdfViewerController();
  final _words = <int, Future<List<WordBox>>>{};
  InkStore? _store;

  /// Pages written on from two devices, waiting for the user.
  ConflictSession? _conflicts;
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

  /// A note is shown from memory. Adding a page rewrites it, and a new name
  /// ([_docVersion]) makes the viewer load the new one.
  Uint8List? _noteBytes;
  int _docVersion = 0;
  bool _growing = false;

  /// The page to show once the viewer has loaded the grown note.
  int? _goAfterLoad;

  /// Where each page shown comes from: the book's own pages and the blank
  /// pages added between them (see [PageMap]).
  PageMap _map = PageMap.none;

  /// The book with its added pages, while it has some; the viewer reads the
  /// book's file directly otherwise.
  PdfDocument? _mixed;

  /// Documents no longer shown, closed a moment later (the viewer may still
  /// be letting go of them), and all of them when the reader closes.
  final _spentDocs = <PdfDocument>[];
  final _liveDocs = <PdfDocument>[];

  int _keyOf(int place) => _map.keyOf(place);
  int _placeOf(int key) => _map.placeOf(key);

  /// The page in view as the book knows it (see [PageMap]).
  int get _keyNow => _keyOf(_viewer.pageNumber ?? 1);

  /// Pages of the book itself, without the added ones.
  int get _bookPageCount => _map.isNone ? _viewer.pageCount : _map.bookPages;

  /// The book has added pages: it is shown from [_mixed].
  bool get _wantsMix =>
      !widget.book.isNote && (_prefs?.extras.isNotEmpty ?? false);

  /// Builds the book with its added pages in their places, and shows it at
  /// [showKey] (else at the page in view).
  Future<void> _assemble({int? showKey}) async {
    final pr = _prefs;
    if (pr == null || widget.book.isNote) return;
    final keep = showKey ?? (_viewer.isReady ? _keyNow : null);
    final extras = pr.extras;
    if (extras.isEmpty) {
      if (_mixed == null) return;
      _retireDocs();
      setState(() {
        _mixed = null;
        _map = PageMap.none;
        _docVersion++;
        _goAfterLoad = keep;
      });
      return;
    }
    final doc = await PdfDocument.openFile(widget.library.pathOf(widget.book));
    final first = doc.pages.first;
    // One small document per added page, on its own paper, the size of the
    // book's pages (a template page keeps its own).
    final sheets = <int, PdfDocument>{};
    for (final e in extras) {
      final paper = e.paper.isEmpty
          ? const PaperStyle(kind: PaperKind.blank).encode()
          : e.paper;
      sheets[e.key] = await PdfDocument.openData(
        await Paper.pdf(
          paper,
          pages: 1,
          stamp: '${widget.book.id}-${e.id}',
          width: first.width,
          height: first.height,
        ),
        sourceName: 'sheet-${widget.book.id}-${e.id}-$_docVersion',
      );
    }
    if (_outline.isEmpty) await _loadOutline(doc);
    final map = PageMap.build(doc.pages.length, extras);
    final own = doc.pages.toList();
    doc.pages = [
      for (final key in map.keys)
        isExtraKey(key) ? sheets[key]!.pages.first : own[key - 1],
    ];
    if (!mounted) {
      await doc.dispose();
      for (final d in sheets.values) {
        await d.dispose();
      }
      return;
    }
    _retireDocs();
    _liveDocs.addAll([doc, ...sheets.values]);
    setState(() {
      _mixed = doc;
      _map = map;
      _docVersion++;
      _goAfterLoad = keep == null ? null : map.placeOf(keep);
    });
  }

  void _retireDocs() {
    final old = List.of(_liveDocs);
    _liveDocs.clear();
    _spentDocs.addAll(old);
    Timer(const Duration(seconds: 3), () {
      for (final d in old) {
        if (_spentDocs.remove(d)) unawaited(d.dispose());
      }
    });
  }

  /// A blank page after the page in view (after the book page an added
  /// page follows).
  Future<void> _addExtraPage() async {
    final pr = _prefs;
    if (pr == null || !_viewer.isReady || widget.book.isNote) return;
    final key = _keyNow;
    final after = isExtraKey(key)
        ? (pr.extras.where((e) => e.key == key).firstOrNull?.after ?? 0)
        : key;
    // The same papers as a note: plain, lined, squared, or a template.
    final picked = await showNotsSheet<Object>(
      context,
      builder: (_) => const NewPaperSheet(forPage: true),
    );
    final String paper;
    if (picked is PaperStyle) {
      paper = picked.encode();
    } else if (picked is PaperTemplate) {
      paper = picked.code;
    } else {
      return;
    }
    if (!mounted) return;
    final e = pr.addExtra(after, paper: paper);
    await pr.flush();
    await _assemble(showKey: e.key);
    _say(
      'أُضيفت صفحة فارغة بعد الصفحة $after. اضغط مطولاً على شريطها لنقلها أو حذفها.',
    );
  }

  /// What can be done with an added page: move it after another page, or
  /// remove it with what is written on it.
  Future<void> _extraActions(ExtraPage e) async {
    final r = await showNotsSheet<String>(
      context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader('صفحة مضافة (بعد الصفحة ${e.after})'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: ActionRows(
                rows: [
                  ActionRow(
                    Icons.drive_file_move_outline,
                    'نقلها إلى صفحة أخرى',
                    () => Navigator.pop(context, 'move'),
                  ),
                  ActionRow(
                    Icons.delete_outline,
                    'حذف الصفحة وما كُتب عليها',
                    () => Navigator.pop(context, 'remove'),
                    danger: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    final pr = _prefs;
    if (pr == null) return;
    if (r == 'move') {
      final to = await _askPageNumber(e.after);
      if (to == null) return;
      pr.moveExtra(e.id, to);
      await pr.flush();
      await _assemble(showKey: e.key);
    } else if (r == 'remove') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('حذف الصفحة المضافة؟'),
          content: const Text('تُحذف الصفحة وكل ما كتبته عليها.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('تراجع'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      _store?.document.replacePage(e.key, const [], const []);
      pr.removeExtra(e.id);
      await pr.flush();
      await _assemble(showKey: e.after < 1 ? 1 : e.after);
    }
  }

  /// Asks after which page of the book an added page goes.
  Future<int?> _askPageNumber(int current) async {
    final c = TextEditingController(text: '$current');
    final n = await showDialog<int>(
      context: context,
      builder: (context) {
        void done() {
          final v = int.tryParse(c.text.trim());
          if (v != null) Navigator.pop(context, v);
        }

        return AlertDialog(
          title: const Text('ضعها بعد الصفحة'),
          content: TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: '0 لتكون قبل الصفحة الأولى، وحتى $_bookPageCount',
            ),
            onSubmitted: (_) => done(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('تراجع'),
            ),
            FilledButton(onPressed: done, child: const Text('نقل')),
          ],
        );
      },
    );
    c.dispose();
    return n?.clamp(0, _bookPageCount);
  }

  /// Last place read and bookmarks of this book.
  ReaderPrefs? _prefs;
  bool _restored = false;

  /// Saves the place shortly after the page stops moving.
  Timer? _placeTimer;

  /// Keeps everything on disk when the app leaves the screen: Android may
  /// end it from there without warning.
  late final AppLifecycleListener _lifecycle;

  /// The colours offered in the tools and the text selection menu.
  final _palette = ColorPalette();
  static const _commentColor = 0xFF0D47A1;

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
      page: _keyOf(n),
      center: Offset(page.width / 2, page.height / 2),
      length: math.min(page.width * 0.85, 480),
      thickness: zoom > 0 ? (90 / zoom).clamp(40.0, 140.0) : 54,
    );
    // The ruler works with the writing tools.
    if (!_tools.drawing) _tools.setMode(ToolMode.pen);
  }

  /// The bars (back, tools, buttons) and the page number come with a tap in
  /// the page (or on the small round button), and go as soon as writing
  /// starts, leaving the whole screen to the page.
  bool _toolsShown = true;

  Future<void> _openConflicts(InkStore store) async {
    final waiting = await ConflictStore.load(widget.book.id);
    if (!mounted || waiting.isEmpty) return;
    final old = _conflicts;
    setState(() {
      _conflicts = ConflictSession(widget.book.id, store.document, waiting);
    });
    old?.dispose();
  }

  void _conflictSettled(PageConflict c) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('اعتُمدت هذه الصفحة.'),
        action: SnackBarAction(
          label: 'تراجع',
          onPressed: () => _conflicts?.reopen(c),
        ),
      ),
    );
  }

  Widget _conflictBar(ConflictSession session) => ListenableBuilder(
    listenable: Listenable.merge([session, _viewer]),
    builder: (context, _) => ConflictBar(
      session: session,
      page: _viewer.isReady ? _keyNow : 1,
      onGoTo: (n) => _goToPlace(_placeOf(n)),
      onAccepted: _conflictSettled,
    ),
  );

  /// The bars come with a tap in the page (or on the small tab at the top)
  /// and go away by themselves a few seconds after the last use, leaving the
  /// whole screen to the page, as they always did.
  Timer? _hideTimer;
  static const _barsLinger = Duration(seconds: 5);
  bool _immersive = false;

  void _showTools() {
    _hideTimer?.cancel();
    if (!_toolsShown) setState(() => _toolsShown = true);
    _hideTimer = Timer(_barsLinger, _hideTools);
    if (_immersive) _systemBars(true);
  }

  void _hideTools() {
    _hideTimer?.cancel();
    if (!mounted) return;
    // Something chosen keeps its bar (delete, copy, colour); an open panel
    // (colours, the box) stays until it is used or closed.
    if ((_selection?.active ?? false) || _pop != ReaderPop.none) {
      _hideTimer = Timer(_barsLinger, _hideTools);
      return;
    }
    if (_toolsShown) setState(() => _toolsShown = false);
  }

  /// "The clean screen" from the menu: the bars go at once, and the phone's
  /// own status and navigation bars with them, until the page is tapped.
  void _cleanScreen() {
    if (_pop != ReaderPop.none) setState(() => _pop = ReaderPop.none);
    _hideTools();
    _systemBars(false);
  }

  void _systemBars(bool shown) {
    _immersive = !shown;
    SystemChrome.setEnabledSystemUIMode(
      shown ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _toggleTools() => _toolsShown ? _hideTools() : _showTools();

  void _onSettings() {
    _tools.setFingerDraws(AppSettings.instance.fingerDraws);
    unawaited(AppSettings.instance.applyAwake(reading: true));
  }

  /// Word boxes already loaded, per page, for instant taps.
  final _wordsReady = <int, List<WordBox>>{};

  /// From the reader's start to its first page, for the speed log.
  final _openClock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    SpeedLog.instance.screen = 'reader';
    _tools.addListener(_onToolChanged);
    _showTools();
    _palette.load();
    AppSettings.instance.addListener(_onSettings);
    unawaited(_layout.load());
    unawaited(AppSettings.instance.applyAwake(reading: true));
    _lifecycle = AppLifecycleListener(onHide: _saveNow);
    ReaderPrefs.open(widget.book.id).then((pr) {
      if (!mounted) {
        pr.dispose();
        return;
      }
      setState(() => _prefs = pr);
      if (_wantsMix) {
        _assemble().then((_) => _restorePage());
      } else {
        _restorePage();
      }
    });
    // A note has no book text to look for.
    if (!widget.book.isNote) {
      BookLinkStore.open(widget.book.id, widget.library.pathOf(widget.book)).then(
        (b) {
          if (mounted && b != null) _bookArrived(b);
        },
      );
    }
    _openInk();
    if (widget.book.isNote) unawaited(_loadNote());
  }

  /// Reads the note's PDF. Pages added on another device (the count comes
  /// with the reading state) are added here too.
  Future<void> _loadNote() async {
    try {
      var bytes = await File(widget.library.pathOf(widget.book)).readAsBytes();
      final saved =
          (await ReaderPrefs.peekProgress(widget.book.id))?.count ?? 0;
      if (saved > notePageCount(bytes)) {
        bytes = await setNotePages(widget.library, widget.book, saved);
      }
      if (mounted) setState(() => _noteBytes = bytes);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Gives the note [pages] sheets and shows page [goTo] (or the one in
  /// view) once they are loaded.
  Future<void> _setNotePages(int pages, {int? goTo}) async {
    if (_growing) return;
    _growing = true;
    try {
      final bytes = await setNotePages(widget.library, widget.book, pages);
      _prefs?.setPageCount(pages);
      if (!mounted) return;
      setState(() {
        _noteBytes = bytes;
        _docVersion++;
        _goAfterLoad = goTo ?? _pageNow.value;
      });
    } on Object catch (e) {
      _say('تعذّرت إضافة الصفحة: $e');
    } finally {
      _growing = false;
    }
  }

  /// A new blank sheet after the last one.
  void _addNotePage() {
    if (!_viewer.isReady || _growing) return;
    final n = _viewer.pageCount + 1;
    unawaited(_setNotePages(n, goTo: n));
  }

  /// Writing came (from another device) on pages the note does not have yet.
  void _fitNoteToWriting() {
    if (!widget.book.isNote || !_viewer.isReady || _noteBytes == null) return;
    final pages = _annotatedPages;
    if (pages.isEmpty) return;
    final last = pages.reduce(math.max);
    if (last > _viewer.pageCount) unawaited(_setNotePages(last));
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
        _selection = SelectionController(s.document)
          ..addListener(() {
            // Something chosen: its bar must be on the screen.
            if (_selection?.active ?? false) _showTools();
          });
      });
      _fitNoteToWriting();
      unawaited(_openConflicts(s));
      // Writing left from older versions can only belong to a book.
      if (!widget.book.isNote &&
          s.document.strokeCount == 0 &&
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
    _hideTimer?.cancel();
    _pageNow.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    AppSettings.instance.removeListener(_onSettings);
    unawaited(AppSettings.instance.applyAwake(reading: false));
    _tools.removeListener(_onToolChanged);
    _conflicts?.dispose();
    _lifecycle.dispose();
    _viewer.removeListener(_onViewMoved);
    _placeTimer?.cancel();
    _capturePlace();
    _store?.dispose();
    _selection?.dispose();
    _tools.dispose();
    _prefs?.dispose();
    _searchShown.dispose();
    _palette.dispose();
    for (final d in [..._liveDocs, ..._spentDocs]) {
      unawaited(d.dispose());
    }
    super.dispose();
  }

  /// Reopen the book exactly where it was left, at the same zoom (once both
  /// the viewer and the saved place are ready).
  void _restorePage() {
    final pr = _prefs;
    if (_restored || pr == null || !_viewer.isReady) return;
    _restored = true;
    pr.setPageCount(_bookPageCount);
    _viewer.addListener(_onViewMoved);
    final pos = pr.position;
    if (pos != null &&
        pos.page >= 1 &&
        _placeOf(pos.page) <= _viewer.pageCount) {
      final zoom = pos
          .zoomFor(_viewer.coverScale)
          .clamp(_viewer.minScale, _viewer.maxScale);
      _viewer.goTo(
        _viewer.calcMatrixFor(
          pos.centerIn(_viewer.layout.pageLayouts[_placeOf(pos.page) - 1]),
          zoom: zoom,
        ),
        duration: Duration.zero,
      );
    } else if (pr.lastPage > 1 && pr.lastPage <= _bookPageCount) {
      // Saved by a version that kept only the page.
      _viewer.goToPage(
        pageNumber: _placeOf(pr.lastPage),
        duration: Duration.zero,
      );
    }
  }

  /// Shows page [place]. The sizes of pages not loaded yet are guessed, so
  /// a long jump can fall short; it is made again until it lands.
  Future<void> _goToPlace(int place) async {
    if (!_viewer.isReady) return;
    await _viewer.goToPage(pageNumber: place);
    for (var i = 0; i < 6 && mounted && _viewer.pageNumber != place; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || !_viewer.isReady) return;
      await _viewer.goToPage(pageNumber: place, duration: Duration.zero);
    }
  }

  /// The page in view; changes only when another page comes.
  final _pageNow = ValueNotifier<int>(1);

  void _onViewMoved() {
    _pageNow.value = _viewer.pageNumber ?? _pageNow.value;
    _placeTimer?.cancel();
    _placeTimer = Timer(const Duration(milliseconds: 500), _capturePlace);
  }

  void _capturePlace() {
    final pr = _prefs;
    if (pr == null || !_restored || !_viewer.isReady) return;
    final n = _viewer.pageNumber;
    if (n == null) return;
    pr.setPosition(
      ReadingPosition.capture(
        page: _keyOf(n),
        pageRect: _viewer.layout.pageLayouts[n - 1],
        center: _viewer.centerPosition,
        zoom: _viewer.currentZoom,
        fit: _viewer.coverScale,
      ),
    );
  }

  void _saveNow() {
    _placeTimer?.cancel();
    _capturePlace();
    unawaited(_prefs?.flush());
    unawaited(_store?.flush());
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

  Future<void> _openPages(PagesMode mode) async {
    if (!_viewer.isReady) return;
    final page = await showNotsSheet<int>(
      context,
      tall: true,
      builder: (_) => PagesSheet(
        document: _viewer.document,
        pageCount: _viewer.pageCount,
        currentPage: _viewer.pageNumber ?? 1,
        bookmarks: {
          for (final b in _prefs?.bookmarks ?? const <int>[]) _placeOf(b),
        },
        annotated: {
          for (final k in _annotatedPages)
            if (_map.isNone || _map.keys.contains(k)) _placeOf(k),
        },
        mode: mode,
      ),
    );
    if (page != null) await _goToPlace(page);
  }

  /// Words of a page in PDF points with a top-left origin: from the book's
  /// word map when it has one (the source text's exact words, each with its
  /// index in the book), else from the PDF text layer (where the PDF itself
  /// counts y from the bottom).
  Future<List<WordBox>> _wordsOf(PdfPage page) {
    final key = _keyOf(page.pageNumber);
    return _words.putIfAbsent(key, () async {
      if (isExtraKey(key)) return const <WordBox>[];
      final mapped = _mappedWords(key);
      if (mapped != null) {
        _wordsReady[key] = mapped;
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
      _wordsReady[key] = words;
      return words;
    });
  }

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
    final key = _keyOf(page.pageNumber);
    final extra = isExtraKey(key)
        ? _prefs?.extras.where((e) => e.key == key).firstOrNull
        : null;
    return [
      if (_prefs != null) _BookmarkRibbon(prefs: _prefs!, page: key),
      if (book != null && book.embedded && extra == null)
        SearchHighlight(
          search: _searchShown,
          book: book,
          pdfPage: key,
          pageWidthPt: page.width,
        ),
      PageInkOverlay(
        // A new word source (the book's map arrived) means new words; and
        // a page that moved is another page.
        key: ValueKey((book?.embedded ?? false, key)),
        document: store.document,
        tools: _tools,
        selection: selection,
        pageNumber: key,
        pageWidthPt: page.width,
        pageWidthPx: pageRect.width,
        viewChanged: _viewer,
        onCreateItem: _createItem,
        onEditItem: _editItem,
        onCreateMark: _createMark,
        loadWords: () => _wordsOf(page),
      ),
      if (extra != null)
        Positioned(
          top: 6,
          left: 0,
          right: 0,
          child: Center(
            child: ExtraPageTab(
              after: extra.after,
              onActions: () => _extraActions(extra),
            ),
          ),
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
    final action = await _repaintAfter(
      showNotsSheet<String>(
        context,
        builder: (_) => NoteViewSheet(
          text: item.text,
          quote: isMark ? item.quote.trim() : '',
          color: item.color,
        ),
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
    final key = _keyOf(page.pageNumber);
    final items = store.document.itemsOf(key);
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      // Only a note shows something on tap; a plain mark is left alone.
      final hasNote =
          it.kind == ItemKind.pin ||
          (it.kind == ItemKind.mark &&
              (it.text.isNotEmpty || it.style == MarkStyle.comment));
      if (hasNote && itemContains(it, pt)) {
        _previewItem(key, it);
        return true;
      }
      if (it.kind == ItemKind.tape && itemContains(it, pt)) {
        store.document.replaceItem(key, it.copyWith(revealed: !it.revealed));
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
    final marked = annotatedPages(store.document).length;
    final choice = await showNotsSheet<String>(
      context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('تصدير ومشاركة'),
              ActionRows(
                rows: [
                  ActionRow(
                    Icons.photo_outlined,
                    'صورة هذه الصفحة إلى المعرض',
                    () => Navigator.pop(context, 'gal-page'),
                    subtitle: 'تُحفظ مباشرة في معرض الصور مع كتابتك',
                  ),
                  ActionRow(
                    Icons.collections_outlined,
                    'صور الصفحات المكتوب عليها إلى المعرض',
                    () => Navigator.pop(context, 'gal-marked'),
                    subtitle: '$marked صفحة',
                  ),
                  ActionRow(
                    Icons.picture_as_pdf_outlined,
                    'PDF: الصفحات المكتوب عليها',
                    () => Navigator.pop(context, 'pdf-marked'),
                    subtitle: '$marked صفحة مع كتابتك',
                  ),
                  ActionRow(
                    Icons.menu_book_outlined,
                    'PDF: الكتاب كاملاً مع كتابتك',
                    () => Navigator.pop(context, 'pdf-all'),
                  ),
                  ActionRow(
                    Icons.inventory_2_outlined,
                    'ملف نوتس (.nots)',
                    () => Navigator.pop(context, 'nots'),
                    subtitle: 'الكتاب وكتابتك وربط Word والعلامات: يُفتح في التطبيق على أي جهاز وتكمل عليه',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final progress = ValueNotifier<String>('جارٍ التحضير…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x6B091630),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Center(
          child: SizedBox(
            width: 250,
            child: Glass(
              radius: 20,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder(
                    valueListenable: progress,
                    builder: (_, v, _) =>
                        Text(v, style: const TextStyle(fontSize: 14)),
                  ),
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(minHeight: 5),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    try {
      final doc = _mixed == null
          ? _viewer.document
          : await PdfDocument.openFile(widget.library.pathOf(widget.book));
      final title = widget.book.title;
      final page = _map
          .bookPageAt(_viewer.pageNumber ?? 1)
          .clamp(1, doc.pages.length);
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
          await Gal.putImageBytes(png, album: 'قلم المصدر', name: base);
        }
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم حفظ ${pages.length} صورة في المعرض (ألبوم قلم المصدر).',
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
    final action = await showNotsSheet<String>(
      context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('الملف جاهز'),
              ActionRows(
                rows: [
                  ActionRow(
                    Icons.save_alt,
                    'حفظ في الجهاز',
                    () => Navigator.pop(context, 'save'),
                    subtitle: 'اختر المجلد، ويبقى الاسم والامتداد كما هما',
                  ),
                  ActionRow(
                    Icons.ios_share,
                    'مشاركة',
                    () => Navigator.pop(context, 'share'),
                  ),
                ],
              ),
            ],
          ),
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
          _keyOf(r.pageNumber),
          _withBookWords(
            _keyOf(r.pageNumber),
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
      final l = book?.layoutOf(book.bookPageOf(_keyOf(r.pageNumber)));
      if (book != null && l != null) {
        final ids = l.wordsInRects(lineRects(_charBoxes(r)));
        if (ids.isNotEmpty) {
          final t = book.pages[book.bookPageOf(_keyOf(r.pageNumber)) - 1];
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
      final bookPage = book.bookPageOf(_keyOf(r.pageNumber));
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
    _prefs?.toggleBookmark(_keyNow);
    setState(() {});
  }

  /// Text entry with, for text boxes, a live font size control.
  Future<TextDialogResult?> _textDialog({
    required String title,
    String initial = '',
    bool allowDelete = false,
    double? fontSize,
    int? color,
  }) => _repaintAfter(
    showNotsSheet<TextDialogResult>(
      context,
      builder: (_) => TextEntrySheet(
        title: title,
        initial: initial,
        allowDelete: allowDelete,
        fontSize: fontSize,
        color: color,
      ),
    ),
  );

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
      final pdfPages = _viewer.isReady ? _bookPageCount : null;
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
    final pdfPage = _placeOf(book.pdfPageOf(hit.page));
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

  /// Name of the sheet's page and the number of pages, for the pill.
  Widget _pagePill() => ListenableBuilder(
    listenable: _pageNow,
    builder: (context, _) => _viewer.isReady
        ? PagePill(
            page: _map.bookPageAt(_pageNow.value),
            count: _bookPageCount,
            extra: isExtraKey(_keyOf(_pageNow.value)),
            onTap: () => _openPages(PagesMode.all),
          )
        : const SizedBox.shrink(),
  );

  bool get _isBook => !widget.book.isNote;

  /// A tool was chosen, in the bar or in the box.
  void _onTool(ReaderTool t) {
    if (t == ReaderTool.ruler) {
      _toggleRuler();
      setState(() => _pop = ReaderPop.none);
      return;
    }
    if (t == ReaderTool.image) {
      setState(() => _pop = ReaderPop.none);
      unawaited(_addPicture());
      return;
    }
    final same = _tools.mode == t.mode;
    _tools.setMode(t.mode!);
    setState(() {
      // Choosing a tool brings its options (colours first of all); choosing
      // it again takes them away.
      _pop = t.hasOptions
          ? (same && _pop == ReaderPop.options
                ? ReaderPop.none
                : ReaderPop.options)
          : ReaderPop.none;
    });
  }

  ReaderTool get _currentTool {
    for (final t in ReaderTool.values) {
      if (t.mode != null && t.mode == _tools.mode) return t;
    }
    return ReaderTool.hand;
  }

  Future<void> _recolorSelection() async {
    final sel = _selection;
    if (sel == null) return;
    final c = await showColorListDialog(
      context,
      _palette,
      sel.currentColor ?? _tools.color,
    );
    if (c != null) sel.recolor(c);
  }

  Widget _panels() {
    return ListenableBuilder(
      listenable: Listenable.merge([_tools, _selection!, _layout]),
      builder: (context, _) {
        final Widget? panel;
        if (_selection!.active) {
          panel = SelectionBar(
            selection: _selection!,
            onColor: _recolorSelection,
          );
        } else if (_pop == ReaderPop.box) {
          panel = ToolBox(
            layout: _layout,
            tools: _tools,
            isBook: _isBook,
            onTool: _onTool,
            onSettings: () {
              setState(() => _pop = ReaderPop.none);
              _openSettings();
            },
          );
        } else if (_pop == ReaderPop.options && _currentTool.hasOptions) {
          panel = ToolOptions(
            tools: _tools,
            palette: _palette,
            fingerDraws: _tools.fingerDraws,
            onFinger: AppSettings.instance.setFingerDraws,
            onColor: () => setState(() => _pop = ReaderPop.none),
          );
        } else {
          panel = null;
        }
        if (panel == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Center(child: panel),
        );
      },
    );
  }

  Widget _bars(BuildContext context) {
    final bars = ListenableBuilder(
      listenable: Listenable.merge([_pageNow, ?_prefs]),
      builder: (context, _) => ReaderBars(
        tools: _tools,
        layout: _layout,
        document: _store!.document,
        selection: _selection!,
        isBook: _isBook,
        bookmarked:
            _viewer.isReady &&
            (_prefs?.isBookmarked(_keyOf(_pageNow.value)) ?? false),
        boxOpen: _pop == ReaderPop.box,
        onBack: () => Navigator.of(context).maybePop(),
        onMasdar: _openMasdar,
        onHistory: _showRecent,
        onToc: _openToc,
        onSearch: _openSearch,
        onBookmark: _toggleBookmark,
        onMore: _openMenu,
        onTool: _onTool,
        onBox: () => setState(
          () => _pop = _pop == ReaderPop.box ? ReaderPop.none : ReaderPop.box,
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bars,
        if (_search != null && _book != null) _searchBanner(context),
        _panels(),
      ],
    );
  }

  /// The last books opened, from inside a book: choosing one opens it in
  /// place of this one.
  Future<void> _showRecent() async {
    final lib = widget.library;
    final books = lib.recentlyRead();
    final progress = ReadProgress();
    unawaited(progress.load(books.map((b) => b.id)));
    final picked = await showNotsSheet<BookEntry>(
      context,
      builder: (_) => HistorySheet(books: books, progress: progress),
    );
    progress.dispose();
    if (picked == null || !mounted || picked.id == widget.book.id) return;
    if (!lib.isOnDevice(picked)) {
      _say('هذا الكتاب في حسابك: افتحه من «كتبي» ليُنزَّل.');
      return;
    }
    await lib.touch(picked);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(library: lib, book: picked),
      ),
    );
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openToc() async {
    final page = await showNotsSheet<int>(
      context,
      builder: (_) => TocSheet(
        entries: _tocEntries,
        currentPdfPage: _viewer.isReady ? _keyNow : 1,
        onLink: () {
          Navigator.of(context).pop();
          _linkDocx();
        },
      ),
    );
    if (page != null) await _goToPlace(_placeOf(page));
  }

  Future<void> _openMenu() async {
    final r = await showNotsSheet<String>(
      context,
      builder: (_) => ReaderMenuSheet(
        annotated: _annotatedPages.length,
        marked: _prefs?.bookmarks.length ?? 0,
        isBook: _isBook,
        linked: _book != null,
        canUnlink: _book != null && !_book!.embedded,
      ),
    );
    switch (r) {
      case 'export':
        await _export();
      case 'annotated':
        await _openPages(PagesMode.annotated);
      case 'marks':
        await _openPages(PagesMode.bookmarks);
      case 'pages':
        await _openPages(PagesMode.all);
      case 'clean':
        _cleanScreen();
      case 'addpage':
        await _addExtraPage();
      case 'tools':
        await _openSettings();
      case 'link':
        await _linkDocx();
      case 'unlink':
        await _unlinkDocx();
    }
  }

  Future<void> _openSettings() => showNotsSheet<void>(
    context,
    builder: (_) => ToolSettingsSheet(layout: _layout, isBook: _isBook),
  );

  /// Opens the Masdar app (when it is on this phone).
  Future<void> _openMasdar() async {
    var opened = false;
    try {
      opened =
          await const MethodChannel('nots/app')
              .invokeMethod<bool>('openApp', {'package': masdarPackage}) ??
          false;
    } on MissingPluginException {
      opened = false;
    }
    if (!opened) _say('تطبيق المصدر غير مثبت على هذا الجهاز.');
  }

  /// Asks for a picture and puts it on the page in view, selected, ready to
  /// be moved and resized.
  Future<void> _addPicture() async {
    final src = await showNotsSheet<ImageSource>(
      context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('إضافة صورة'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: ActionRows(
                rows: [
                  ActionRow(
                    Icons.photo_library_outlined,
                    'من المعرض',
                    () => Navigator.pop(context, ImageSource.gallery),
                  ),
                  // A computer has no camera to take a picture with here.
                  if (Platform.isAndroid || Platform.isIOS)
                    ActionRow(
                      Icons.photo_camera_outlined,
                      'من الكاميرا',
                      () => Navigator.pop(context, ImageSource.camera),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final store = _store;
    if (src == null || !mounted || store == null || !_viewer.isReady) return;
    try {
      final file = await ImagePicker().pickImage(source: src);
      if (file == null || !mounted) return;
      final prepared = await prepareImage(await file.readAsBytes());
      if (prepared == null) {
        _say('تعذّرت قراءة الصورة.');
        return;
      }
      final n = _viewer.pageNumber ?? 1;
      final page = _viewer.document.pages[n - 1];
      final rect = _viewer.layout.pageLayouts[n - 1];
      // The middle of the screen, if it is on this page; else the page's.
      final c = _viewer.centerPosition - rect.topLeft;
      final center = Offset(
        c.dx.clamp(page.width * 0.25, page.width * 0.75),
        c.dy.clamp(page.height * 0.2, page.height * 0.8),
      );
      final doc = store.document;
      final item = pictureItem(
        id: doc.takeStrokeId(),
        image: prepared,
        center: center,
        width: page.width * 0.55,
      );
      doc.addItem(_keyOf(n), item);
      // Selected: it can be moved by its body and resized by its corners.
      _tools.setMode(ToolMode.lasso);
      _selection?.selectItem(_keyOf(n), item.id);
    } on Object catch (e) {
      _say('تعذّرت إضافة الصورة: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final wide = size.width >= wideBars;
    _viewWidth = size.width;
    final belowBars = pad.top + (wide ? 56 : 108);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brand.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: Brand.dark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: wide ? Brand.desk : Brand.paper,
        // The keyboard (writing a comment or a note) must not squeeze the
        // page: that re-lays it out and can leave it drawn blurry. Sheets
        // make room for the keyboard themselves.
        resizeToAvoidBottomInset: false,
        body: _error != null
            ? Center(child: Text('تعذّر فتح ملف الكتابة: $_error'))
            : store == null || _selection == null
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  Positioned.fill(child: _viewerArea()),
                  if (_conflicts != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      top: belowBars + 8,
                      child: _conflictBar(_conflicts!),
                    ),
                  Positioned(
                    left: 0,
                    top: belowBars + 10,
                    bottom: pad.bottom + 70,
                    width: 60,
                    child: ScrubBar(controller: _viewer, shown: _toolsShown),
                  ),
                  // The page number, at the bottom.
                  Positioned(
                    bottom: pad.bottom + 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: IgnorePointer(
                        ignoring: !_toolsShown,
                        child: AnimatedOpacity(
                          opacity: _toolsShown ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: _pagePill(),
                        ),
                      ),
                    ),
                  ),
                  // A note grows a page at a time.
                  if (widget.book.isNote)
                    PositionedDirectional(
                      end: 14,
                      bottom: pad.bottom + 12,
                      child: AddPageButton(onPressed: _addNotePage),
                    ),
                  // While the bars are away: a small round button showing
                  // the tool in use brings them back (as does a tap on the
                  // page with the hand tool).
                  Positioned(
                    top: pad.top + 2,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: IgnorePointer(
                        ignoring: _toolsShown,
                        child: AnimatedOpacity(
                          opacity: _toolsShown ? 0 : 1,
                          duration: const Duration(milliseconds: 200),
                          child: ListenableBuilder(
                            listenable: _tools,
                            builder: (context, _) => ToolDot(
                              icon: _currentTool.icon,
                              color: _tools.drawing
                                  ? Color(_tools.color)
                                  : null,
                              onTap: _showTools,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: pad.top,
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
                            child: _bars(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _viewerArea() {
    final wide = _viewWidth >= wideBars;
    if (widget.book.isNote && _noteBytes == null ||
        !widget.book.isNote &&
            (_prefs == null || _wantsMix && _mixed == null)) {
      return const Center(child: CircularProgressIndicator());
    }
    return TouchNavigator(
      tools: _tools,
      readView: () => _viewer.isReady ? _viewer.value : null,
      writeView: (m) {
        if (_viewer.isReady) _viewer.value = m;
      },
      // Starting to write clears the screen: the bars and their panels go,
      // and only the page is left.
      child: Listener(
        onPointerDown: (_) {
          // A touch on the page while a panel is open closes the panel.
          if (_tools.drawing && _pop != ReaderPop.none) {
            setState(() => _pop = ReaderPop.none);
          }
        },
        child: ListenableBuilder(
          listenable: _tools,
          builder: (context, _) => _cachedViewer(
            wide,
            () => _pdfViewer(
              PdfViewerParams(
                // Margins, page layout and image cache as in the earlier
                // version: zooming and moving felt steady there.
                backgroundColor: wide ? Brand.desk : Brand.paper,
                pageDropShadow: wide
                    ? const BoxShadow(
                        color: Color(0x2916233A),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      )
                    : null,
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
                  if (_openClock.isRunning) {
                    _openClock.stop();
                    SpeedLog.instance.took(
                      'reader: open to first page',
                      _openClock.elapsedMilliseconds,
                      '${doc.pages.length} pages',
                    );
                  }
                  if (_mixed == null) _loadOutline(doc);
                  _restorePage();
                  final go = _goAfterLoad;
                  if (go != null) {
                    _goAfterLoad = null;
                    _viewer.goToPage(
                      pageNumber: go.clamp(1, _viewer.pageCount),
                      duration: Duration.zero,
                    );
                  }
                  _fitNoteToWriting();
                },
                onPageChanged: (n) {
                  if (n == null) return;
                  _prefs?.setLastPage(_keyOf(n));
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
    );
  }

  /// The book from its file; a note from memory, under a name that changes
  /// with each new page.
  Widget _pdfViewer(PdfViewerParams params) => widget.book.isNote
      ? PdfViewer.data(
          _noteBytes!,
          sourceName: 'note-${widget.book.id}-$_docVersion',
          controller: _viewer,
          params: params,
        )
      : _mixed != null
      ? PdfViewer(
          PdfDocumentRefDirect(
            _mixed!,
            autoDispose: false,
            key: PdfDocumentRefKey('mixed-${widget.book.id}', [_docVersion]),
          ),
          controller: _viewer,
          params: params,
        )
      : PdfViewer.file(
          widget.library.pathOf(widget.book),
          controller: _viewer,
          params: params,
        );

  Widget? _viewerWidget;
  (bool, bool, int)? _viewerKey;

  /// The same viewer widget while nothing it depends on changed, so Flutter
  /// does not touch it at all.
  Widget _cachedViewer(bool wide, Widget Function() build) {
    final key = (_tools.drawing, wide, _docVersion);
    if (_viewerWidget == null || key != _viewerKey) {
      _viewerKey = key;
      _viewerWidget = build();
    }
    return _viewerWidget!;
  }
}

/// The ribbon on a bookmarked page.
class _BookmarkRibbon extends StatelessWidget {
  const _BookmarkRibbon({required this.prefs, required this.page});

  final ReaderPrefs prefs;
  final int page;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: prefs,
    builder: (context, _) => prefs.isBookmarked(page)
        ? const Positioned(
            top: 0,
            right: 14,
            child: IgnorePointer(
              child: Icon(Icons.bookmark, color: Brand.gold, size: 30),
            ),
          )
        : const SizedBox.shrink(),
  );
}
