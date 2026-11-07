// Pictures of the main screens, drawn with the app's own font and theme into
// build/screens/. They are for looking at (flutter test --update-goldens
// test/screens_test.dart); the tests only check that the screens build.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/catalog/book_detail_screen.dart';
import 'package:nots/catalog/catalog_screen.dart';
import 'package:nots/catalog/catalog_store.dart';
import 'package:nots/catalog/cover_image.dart';
import 'package:nots/catalog/download_manager.dart';
import 'package:nots/library/book_widgets.dart';
import 'package:nots/library/books_tab.dart';
import 'package:nots/library/home_bar.dart';
import 'package:nots/library/home_sheets.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/library/notes_tab.dart';
import 'package:nots/notes/paper.dart';
import 'package:nots/reader/reader_prefs.dart';
import 'package:nots/ui/theme.dart';
import 'package:nots/sync/google_account.dart';
import 'package:nots/sync/sync_engine.dart';
import 'package:nots/sync/sync_sheet.dart';
import 'package:path/path.dart' as p;

const _books = [
  (435, 'منهاج الصالحين', 'السيد السيستاني', 'الفقه', 3),
  (448, 'المسائل المنتخبة', 'السيد السيستاني', 'الفقه', 1),
  (7045, 'الأحكام الفقهية', 'السيد الحكيم', 'الفقه', 1),
  (446, 'العروة الوثقى فيما تعم به البلوى', 'السيد اليزدي', 'الفقه', 2),
  (1034, 'أصول الفقه', 'الشيخ المظفر', 'أصول الفقه', 2),
  (7041, 'منهاج الصالحين', 'السيد الحكيم', 'الفقه', 3),
  (449, 'نهج البلاغة', 'الشريف الرضي', 'الحديث الشريف', 1),
  (1, 'الكافي', 'الشيخ الكليني', 'الحديث الشريف', 8),
  (7001, 'المحكم في أصول الفقه', 'السيد الحكيم', 'أصول الفقه', 6),
];

late Directory _root;
late LibraryStore _lib;
late CatalogStore _catalog;
final _progress = ReadProgress();

Map<String, Object> _part(int n, int pages) => {
  'n': n,
  'label': 'الجزء $n',
  'format': 'pdf',
  'file': 'x/$n.pdf',
  'size': 4 * 1048576 + n * 300000,
  'sha256': '',
  'pages': pages,
  'features': {'search': true, 'marks': true, 'copy': n == 1, 'toc': true},
};

Future<void> _setUp() async {
  _root = await Directory.systemTemp.createTemp('nots_shots_');
  final covers = Directory(p.join(_root.path, 'covers'))..createSync();
  for (final b in _books) {
    File('../des/assets/images/covers/${b.$1}.jpg').copySync(p.join(covers.path, '${b.$1}.jpg'));
  }
  CoverCache.dirProvider = () async => covers;
  ReaderPrefs.dirProvider = () async => Directory(p.join(_root.path, 'prefs'));
  _lib = await LibraryStore.openAt(_root);
  var n = 0;
  for (final b in _books.take(6)) {
    final f = File(p.join(_root.path, 'src$n.pdf'))
      ..writeAsBytesSync(List.generate(3000, (i) => (i * 7 + n * 13) & 255));
    final e = await _lib.importPdf(f.path, title: b.$2);
    await _lib.linkCatalog(
      e,
      catalogId: 'b${b.$1}',
      part: 1,
      title: b.$2,
      author: b.$3,
      subject: b.$4,
      cover: 'covers/${b.$1}.jpg',
    );
    n++;
  }
  final shown = [for (final e in _lib.books) e];
  for (var i = 0; i < shown.length; i++) {
    final pr = await ReaderPrefs.open(shown[i].id);
    pr.setLastPage(10 + i * 37);
    pr.setPageCount(520);
    await pr.flush();
  }
  // One book that is in the account but not yet on this device.
  await _lib.offload(shown[4]);
  final json = jsonEncode({
    'format': 'nots-catalog',
    'version': 1,
    'updated': 'x',
    'books': [
      for (final b in _books)
        {
          'id': 'b${b.$1}',
          'title': b.$2,
          'author': b.$3,
          'subject': b.$4,
          'language': 'العربية',
          'publisher': 'دار الهلال',
          'added': '2026-0${b.$5}-01',
          'cover': 'covers/${b.$1}.jpg',
          'parts_count': b.$5,
          'parts': [for (var k = 1; k <= b.$5; k++) _part(k, 300 + k * 20)],
        },
    ],
  });
  _catalog = CatalogStore(_root, bundled: () async => json);
  await _catalog.load();
  await _progress.load(_lib.ids);
  await _lib.importPdf(
    (File(p.join(_root.path, 'n.pdf'))..writeAsBytesSync([1, 2, 3, 4, 5, 6])).path,
    title: 'أقسام الماء',
  );
  for (final e in _lib.books.where((e) => e.title == 'أقسام الماء')) {
    await _lib.markNote(e, template: const PaperStyle(kind: PaperKind.grid, paper: 0xFFFFFFFF, line: 0xFFB9C7DA).encode());
  }
  for (final (i, title, style) in [
    (1, 'الأوامر: تلخيص الدرس', const PaperStyle(kind: PaperKind.lined, paper: 0xFFFBF8F1, line: 0xFFD6CFBE)),
    (2, 'ماء المطر', const PaperStyle(kind: PaperKind.lined, paper: 0xFFFFF4CC, line: 0xFFC8372D)),
    (3, 'ملاحظة بلا عنوان', const PaperStyle(kind: PaperKind.blank, paper: 0xFF1D2636, line: 0xFFB9C7DA)),
  ]) {
    final f = File(p.join(_root.path, 'n$i.pdf'))..writeAsBytesSync([i, i + 1, i + 2]);
    final e = await _lib.importPdf(f.path, title: title);
    await _lib.markNote(e, template: style.encode());
  }
}

Widget _app(Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('ar'),
  supportedLocales: const [Locale('ar')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: buildTheme(),
  home: home,
);

Future<void> _shot(WidgetTester t, Widget w, String name, {Size size = const Size(390, 844)}) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  // Images are read from disk in the real zone; have them ready, at the
  // sizes the screens ask for, before the first frame.
  await t.pumpWidget(const SizedBox());
  final ctx = t.element(find.byType(SizedBox));
  await t.runAsync(() async {
    for (final b in _books) {
      final f = File(p.join(_root.path, 'covers', '${b.$1}.jpg'));
      for (final w in [84, 220, 224, 272, 260, 240]) {
        await precacheImage(ResizeImage(FileImage(f), width: w), ctx);
      }
    }
    for (final a in ['stone', 'tile-script', 'alhikmeh-white-logo']) {
      await precacheImage(AssetImage('assets/images/$a.webp'), ctx);
    }
  });
  await t.pumpWidget(_app(w));
  for (var i = 0; i < 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 350)));
    await t.pump(const Duration(milliseconds: 100));
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screens/$name.png'));
}

Widget _shell(Widget tab, int index) => Scaffold(
  backgroundColor: Brand.paper,
  body: Stack(
    children: [
      Positioned.fill(child: tab),
      HomeBar(tab: index, onTab: (_) {}, onNew: () {}),
    ],
  ),
);

Future<void> _loadFonts() async {
  Future<void> load(String family, List<Uint8List> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(f)));
    }
    await l.load();
  }

  await load('Muna', [
    for (final n in ['Regular', 'Bold', 'Black'])
      File('assets/fonts/Muna-$n.ttf').readAsBytesSync(),
  ]);
  final icons = File('C:/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await load('MaterialIcons', [icons.readAsBytesSync()]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The pictures need the covers of the design folder, which is only on the
  // developer's computer, not in the repository.
  if (!Directory('../des/assets/images/covers').existsSync()) {
    test('screens (needs ../des)', () {}, skip: 'no design folder here');
    return;
  }
  tearDown(() => Brand.dark = false);
  late SyncEngine sync;
  late DownloadManager downloads;
  final account = GoogleAccount();

  setUpAll(() async {
    await _loadFonts();
    await _setUp();
    sync = SyncEngine(_lib, isLinked: () => false, drive: () => throw StateError('no drive'));
    downloads = DownloadManager(_lib, _root);
  });

  const cats = ['الكل', 'الفقه', 'أصول الفقه', 'الحديث الشريف'];

  testWidgets('my books', (t) async {
    await t.runAsync(() async {});
    await _shot(
      t,
      _shell(
        BooksTab(
          library: _lib,
          sync: sync,
          downloads: downloads,
          account: account,
          progress: _progress,
          categories: cats,
          onOpen: (_) {},
          onMore: (_) {},
          onAccount: () {},
          onHistory: () {},
          onBrowse: () {},
          onDriveWarning: () {},
        ),
        0,
      ),
      'my_books',
    );
  });

  testWidgets('the books to download', (t) async {
    await _shot(
      t,
      _shell(
        CatalogScreen(
          store: _catalog,
          downloads: downloads,
          library: _lib,
          account: account,
          categories: cats,
          onOpen: (_) {},
          onAccount: () {},
          onHistory: () {},
        ),
        1,
      ),
      'catalog',
    );
  });

  testWidgets('a book', (t) async {
    await _shot(
      t,
      BookDetailScreen(
        book: _catalog.books.firstWhere((b) => b.id == 'b435'),
        downloads: downloads,
        library: _lib,
        onOpen: (_) {},
      ),
      'book',
    );
  });

  testWidgets('my notes', (t) async {
    await _shot(
      t,
      _shell(
        NotesTab(
          library: _lib,
          account: account,
          onOpen: (_) {},
          onMore: (_) {},
          onAccount: () {},
          onHistory: () {},
          onNew: () {},
        ),
        2,
      ),
      'notes',
    );
  });

  testWidgets('the new paper sheet', (t) async {
    await _shot(t, const Scaffold(body: NewPaperSheet()), 'new_paper');
  });

  testWidgets('the last ten books', (t) async {
    await _shot(
      t,
      Scaffold(
        body: HistorySheet(
          books: _lib.books.where((b) => !b.isNote).toList(),
          progress: _progress,
        ),
      ),
      'history',
    );
  });

  testWidgets('the account', (t) async {
    await _shot(
      t,
      Scaffold(
        body: SyncSheet(account: account, sync: sync, beforeWipe: () {}),
      ),
      'account',
    );
  });

  testWidgets('every paper draws', (t) async {
    await _shot(
      t,
      Scaffold(
        body: GridView.count(
          crossAxisCount: 3,
          padding: const EdgeInsets.all(12),
          childAspectRatio: 0.7,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          children: [
            for (final k in PaperKind.values)
              PaperPreview(PaperStyle(kind: k, paper: 0xFFFBF8F1, line: 0xFFD6CFBE)),
            for (final k in PaperKind.values)
              PaperPreview(PaperStyle(kind: k, paper: 0xFF1D2636, line: 0xFF9AA7B8)),
          ],
        ),
      ),
      'papers',
    );
  });

  // The same screens on tablets: an iPad and an Android tablet.
  const ipad = Size(1194, 834);
  const tab = Size(1280, 800);

  testWidgets('tablet: my books', (t) async {
    await _shot(
      t,
      _shell(
        BooksTab(
          library: _lib,
          sync: sync,
          downloads: downloads,
          account: account,
          progress: _progress,
          categories: cats,
          onOpen: (_) {},
          onMore: (_) {},
          onAccount: () {},
          onHistory: () {},
          onBrowse: () {},
          onDriveWarning: () {},
        ),
        0,
      ),
      'tablet_my_books',
      size: ipad,
    );
  });

  testWidgets('tablet: the books to download', (t) async {
    await _shot(
      t,
      _shell(
        CatalogScreen(
          store: _catalog,
          downloads: downloads,
          library: _lib,
          account: account,
          categories: cats,
          onOpen: (_) {},
          onAccount: () {},
          onHistory: () {},
        ),
        1,
      ),
      'tablet_catalog',
      size: tab,
    );
  });

  testWidgets('tablet: notes and the new paper sheet', (t) async {
    await _shot(
      t,
      _shell(
        NotesTab(
          library: _lib,
          account: account,
          onOpen: (_) {},
          onMore: (_) {},
          onAccount: () {},
          onHistory: () {},
          onNew: () {},
        ),
        2,
      ),
      'tablet_notes',
      size: ipad,
    );
    await _shot(t, const Scaffold(body: Center(child: SizedBox(width: 600, child: NewPaperSheet()))), 'tablet_new_paper', size: ipad);
  });

  // The night look.
  testWidgets('night: my books, the books, notes, account, new paper', (t) async {
    Brand.dark = true;
    Widget books() => BooksTab(
      library: _lib,
      sync: sync,
      downloads: downloads,
      account: account,
      progress: _progress,
      categories: cats,
      onOpen: (_) {},
      onMore: (_) {},
      onAccount: () {},
      onHistory: () {},
      onBrowse: () {},
      onDriveWarning: () {},
    );
    await _shot(t, _shell(books(), 0), 'night_my_books');
    await _shot(
      t,
      _shell(
        CatalogScreen(
          store: _catalog,
          downloads: downloads,
          library: _lib,
          account: account,
          categories: cats,
          onOpen: (_) {},
          onAccount: () {},
          onHistory: () {},
        ),
        1,
      ),
      'night_catalog',
    );
    await _shot(
      t,
      _shell(
        NotesTab(
          library: _lib,
          account: account,
          onOpen: (_) {},
          onMore: (_) {},
          onAccount: () {},
          onHistory: () {},
          onNew: () {},
        ),
        2,
      ),
      'night_notes',
    );
    await _shot(
      t,
      Scaffold(body: SyncSheet(account: account, sync: sync, beforeWipe: () {})),
      'night_account',
    );
    await _shot(t, const Scaffold(body: NewPaperSheet()), 'night_new_paper');
    await _shot(
      t,
      BookDetailScreen(
        book: _catalog.books.firstWhere((b) => b.id == 'b435'),
        downloads: downloads,
        library: _lib,
        onOpen: (_) {},
      ),
      'night_book',
    );
  });
}
