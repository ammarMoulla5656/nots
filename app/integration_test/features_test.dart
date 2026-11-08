// Tries every feature of the reader on a desktop with the real PDF engine and
// reports each step on its own: flutter test integration_test/features_test.dart -d windows
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nots/book/book_link_store.dart';
import 'package:nots/export/exporter.dart';
import 'package:nots/ink/image_items.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/ink/note_items.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/notes/note_pdf.dart';
import 'package:nots/notes/paper.dart';
import 'package:nots/notes/paper_templates.dart';
import 'package:nots/reader/reader_chrome.dart';
import 'package:nots/reader/reader_prefs.dart';
import 'package:nots/reader/reader_screen.dart';
import 'package:nots/reader/tool_layout.dart';
import 'package:nots/sync/conflicts.dart';
import 'package:nots/ui/app_settings.dart';
import 'package:nots/ui/brand_widgets.dart';
import 'package:nots/ui/theme.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

final _key = GlobalKey();
final _results = <String>[];
final _failures = <String>[];

Future<void> _settle(WidgetTester t, [int ms = 700]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<ui.Image> _frame() async {
  final b = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return b.toImage(pixelRatio: 1);
}

Future<void> _shot(WidgetTester t, String name) async {
  await _settle(t, 300);
  final image = await _frame();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File('build/screens/f_$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(data!.buffer.asUint8List());
}

/// Average brightness (0..255) of a rectangle of the screen.
Future<double> _brightness(Rect r) async {
  final image = await _frame();
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  var sum = 0.0, n = 0;
  for (var y = r.top.toInt(); y < r.bottom; y += 4) {
    for (var x = r.left.toInt(); x < r.right; x += 4) {
      final i = (y * image.width + x) * 4;
      sum += (data.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2)) / 3;
      n++;
    }
  }
  return sum / n;
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.tap(f.first);
  await _settle(t, 450);
}

Future<void> _wake(WidgetTester t) async {
  if (find.byType(ToolDot).hitTestable().evaluate().isNotEmpty &&
      find.byTooltip('مربع الأدوات').hitTestable().evaluate().isEmpty) {
    await t.tap(find.byType(ToolDot).first);
    await _settle(t, 450);
  }
}

Future<void> _stroke(WidgetTester t, Offset from, Offset to) async {
  final g = await t.startGesture(from);
  for (var i = 1; i <= 14; i++) {
    await g.moveTo(Offset.lerp(from, to, i / 14)!);
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await _settle(t, 350);
}

Future<void> _closeSheet(WidgetTester t) async {
  final h = find.byType(SheetHeader);
  if (h.evaluate().isEmpty) return;
  Navigator.of(t.element(h.last)).pop();
  await _settle(t, 500);
}

Future<void> _box(WidgetTester t, String label) async {
  await _wake(t);
  await _tap(t, find.byTooltip('مربع الأدوات'));
  await _tap(t, find.text(label));
}

/// What the saved writing of [id] holds.
Future<({int strokes, int items, int pictures})> _saved(String id) async {
  final s = await InkStore.open(id);
  final d = s.document;
  final all = d.items.values.expand((l) => l).toList();
  final r = (
    strokes: d.strokeCount,
    items: all.length,
    pictures: all.where((i) => i.kind == ItemKind.image).length,
  );
  await s.dispose();
  return r;
}

Future<void> step(String name, Future<void> Function() body) async {
  try {
    await body();
    _results.add('PASS  $name');
  } on Object catch (e) {
    _results.add('FAIL  $name  ->  ${e.toString().split('\n').first}');
    _failures.add(name);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every feature of the reader', (t) async {
    await pdfrxFlutterInitialize();
    final root = await Directory.systemTemp.createTemp('nots_features_');
    for (final d in ['prefs', 'ink', 'links', 'conf']) {
      Directory(p.join(root.path, d)).createSync();
    }
    ReaderPrefs.dirProvider = () async => Directory(p.join(root.path, 'prefs'));
    InkStore.dirProvider = () async => Directory(p.join(root.path, 'ink'));
    BookLinkStore.dirProvider = () async => Directory(p.join(root.path, 'links'));
    ConflictStore.dirProvider = () async => Directory(p.join(root.path, 'conf'));
    AppSettings.dirProvider = () async => Directory(p.join(root.path, 'prefs'));
    ToolLayout.dirProvider = () async => Directory(p.join(root.path, 'prefs'));
    final lib = await LibraryStore.openAt(root);
    final book = await lib.importPdf(
      '../نوتس/منهاج الصالحين - الجزء الأول.pdf',
      title: 'منهاج الصالحين - الجزء الأول',
    );
    Future<BookEntry> note([PaperStyle? s]) => createNote(
      lib,
      s ?? const PaperStyle(kind: PaperKind.lined, paper: 0xFFFFFFFF, line: 0xFFB9C7DA),
    );

    Widget app(BookEntry b) => RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(),
        home: ReaderScreen(library: lib, book: b),
      ),
    );

    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);

    Future<void> open(BookEntry b, {int wait = 2500}) async {
      await t.pumpWidget(app(b));
      await _settle(t, wait);
    }

    Future<void> close() async {
      await t.pumpWidget(const SizedBox());
      await _settle(t, 900);
    }

    // ---- writing tools, on a note
    final n1 = await note();
    await open(n1);
    await step('the page is as wide as the screen', () async {
      final b = await _brightness(const Rect.fromLTWH(2, 300, 4, 200));
      expect(b, greaterThan(200), reason: 'no margin at the side: the paper reaches the edge');
    });

    await step('pen writes and is saved', () async {
      await _tap(t, find.byTooltip('قلم'));
      await _tap(t, find.byTooltip('قلم')); // closes its options
      await _stroke(t, const Offset(80, 250), const Offset(300, 270));
      await close();
      expect((await _saved(n1.id)).strokes, 1);
    });

    final n2 = await note();
    await open(n2);
    await step('laser leaves nothing behind', () async {
      await _box(t, 'ليزر');
      await _stroke(t, const Offset(80, 300), const Offset(300, 330));
      await _settle(t, 1300);
      await close();
      final s = await _saved(n2.id);
      expect(s.strokes + s.items, 0);
    });

    final n3 = await note();
    await open(n3);
    await step('bars: stay while writing, go by themselves after a few seconds, the tab brings them back', () async {
      await _tap(t, find.byTooltip('قلم'));
      await _tap(t, find.byTooltip('قلم'));
      await _stroke(t, const Offset(80, 250), const Offset(300, 250));
      expect(find.byTooltip('مربع الأدوات').hitTestable().evaluate(), isNotEmpty);
      await _settle(t, 5800);
      expect(find.byTooltip('مربع الأدوات').hitTestable().evaluate(), isEmpty);
      await _shot(t, '01_bars_away');
      await _wake(t);
      expect(find.byTooltip('مربع الأدوات').hitTestable().evaluate(), isNotEmpty);
    });
    await step('undo and redo', () async {
      await _tap(t, find.byTooltip('تراجع'));
      await _tap(t, find.byTooltip('إعادة'));
      await _tap(t, find.byTooltip('تراجع'));
      await _tap(t, find.byTooltip('إعادة'));
    });
    await step('eraser: the whole stroke goes', () async {
      await _tap(t, find.byTooltip('ممحاة'));
      await _tap(t, find.text('خط كامل'));
      await _tap(t, find.byTooltip('ممحاة'));
      await _stroke(t, const Offset(190, 200), const Offset(190, 300));
      await close();
      expect((await _saved(n3.id)).strokes, 0);
    });

    final n4 = await note();
    await open(n4);
    await step('shapes: an arrow is drawn', () async {
      await _box(t, 'أشكال');
      await _tap(t, find.text('سهم'));
      await _shot(t, '00_shapes');
      await _stroke(t, const Offset(100, 520), const Offset(300, 600));
      await close();
      expect((await _saved(n4.id)).strokes, greaterThanOrEqualTo(1));
    });

    final n5 = await note();
    await open(n5);
    await _box(t, 'نص');
    await step('text: typed in a sheet and placed on the page (2)', () async {
      await _wake(t);
      await t.tapAt(const Offset(150, 300));
      await _settle(t, 700);
      expect(find.byType(TextField), findsOneWidget);
      await t.enterText(find.byType(TextField), 'مراجعة الدرس');
      await _tap(t, find.text('حفظ'));
      await _shot(t, '02_text');
      await close();
      expect((await _saved(n5.id)).items, 1);
    });

    final n6 = await note();
    await open(n6);
    await step('note pin: typed and placed', () async {
      await _box(t, 'ملاحظة');
      await t.tapAt(const Offset(150, 300));
      await _settle(t, 700);
      await t.enterText(find.byType(TextField), 'تعليق');
      await _tap(t, find.text('حفظ'));
      await close();
      expect((await _saved(n6.id)).items, 1);
    });

    final n7 = await note();
    await open(n7);
    await step('tape: a strip is dragged out', () async {
      await _box(t, 'شريط');
      await _stroke(t, const Offset(80, 300), const Offset(260, 350));
      await close();
      expect((await _saved(n7.id)).items, 1);
    });

    // ---- a picture on a page
    final n8 = await note();
    await step('picture: placed, shown, selected, resized, deleted', () async {
      final prepared = await prepareImage(File('../des/assets/images/covers/435.jpg').readAsBytesSync());
      expect(prepared, isNotNull);
      final s = await InkStore.open(n8.id);
      final it = pictureItem(
        id: s.document.takeStrokeId(),
        image: prepared!,
        center: const Offset(297, 300),
        width: 250,
      );
      s.document.addItem(1, it);
      await s.flush();
      await s.dispose();
      await open(n8, wait: 3000);
      // The picture's middle is not the paper's white any more.
      final mid = await _brightness(const Rect.fromLTWH(180, 250, 20, 20));
      await _shot(t, '03_picture');
      expect(mid, lessThan(235));
      // The lasso: a tap on it selects it, and the bar offers to delete it.
      await _tap(t, find.byTooltip('تحديد'));
      await _tap(t, find.byTooltip('تحديد'));
      await t.tapAt(const Offset(190, 260));
      await _settle(t, 600);
      expect(find.text('حذف المحدد'), findsOneWidget);
      await _shot(t, '04_picture_selected');
      await _tap(t, find.text('تكرار المحدد'));
      await close();
      expect((await _saved(n8.id)).pictures, 2);
      await open(n8);
      await _tap(t, find.byTooltip('تحديد'));
      await _tap(t, find.byTooltip('تحديد'));
      await t.tapAt(const Offset(215, 285));
      await _settle(t, 600);
      await _tap(t, find.text('حذف المحدد'));
      await close();
      expect((await _saved(n8.id)).pictures, 1);
    });

    // ---- exporting what was written
    await step('export: a PNG and a PDF of the written pages', () async {
      final doc = await PdfDocument.openFile(lib.pathOf(n8));
      final s = await InkStore.open(n8.id);
      final png = await pagePng(doc, s.document, 1);
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
      final bytes = await exportPdf(doc, s.document, onlyAnnotated: true);
      final out = await PdfDocument.openData(Uint8List.fromList(bytes));
      expect(out.pages.length, 1);
      await out.dispose();
      await doc.dispose();
      await s.dispose();
    });

    // ---- the arrangement of the tools
    final n9 = await note();
    await open(n9);
    await step('tools: dragged from the box into the bar, and kept', () async {
      await _tap(t, find.byTooltip('مربع الأدوات'));
      await _tap(t, find.text('إعدادات الأدوات'));
      final chip = find.descendant(of: find.byType(Draggable<ReaderTool>), matching: find.text('ليزر'));
      final bar = find.text('في الشريط');
      await t.timedDrag(chip.first, t.getCenter(bar.first) - t.getCenter(chip.first) + const Offset(0, 40), const Duration(milliseconds: 600));
      await _settle(t, 600);
      await _shot(t, '05_tool_settings');
      await _tap(t, find.text('تم'));
      await _wake(t);
      expect(find.byTooltip('ليزر'), findsWidgets);
      final saved = File(p.join(root.path, 'prefs', 'tools.json')).readAsStringSync();
      expect(saved.indexOf('laser') < saved.indexOf('box'), isTrue, reason: saved);
    });
    await step('tools: the options of the pen show colours at once, none behind a colour button', () async {
      await _wake(t);
      await _tap(t, find.byTooltip('قلم'));
      expect(find.byTooltip('اللون'), findsNothing);
      expect(find.byType(ToolOptions), findsOneWidget);
    });

    // ---- the real book
    await close();
    await open(book, wait: 3500);
    await step('book: contents sheet shows the real contents', () async {
      await _wake(t);
      await _tap(t, find.byTooltip('الفهرس'));
      expect(find.textContaining('كتاب الطهارة'), findsWidgets);
      await _closeSheet(t);
    });
    await step('book: bookmark is saved', () async {
      await _wake(t);
      await _tap(t, find.byTooltip('وضع علامة على الصفحة'));
      await close();
      final pr = await ReaderPrefs.open(book.id);
      expect(pr.bookmarks, [1]);
      pr.dispose();
    });
    await open(book, wait: 3500);
    await step('book: go to a page by its number', () async {
      await _wake(t);
      await _tap(t, find.byType(PagePill));
      await t.enterText(find.byType(TextField), '35');
      await _tap(t, find.text('انتقال'));
      await _settle(t, 4000);
      expect(find.descendant(of: find.byType(PagePill), matching: find.textContaining('35')), findsWidgets);
      await _shot(t, '06_page_35');
    });
    await step('book: highlighter marks the words it passes over', () async {
      await _wake(t);
      await _tap(t, find.byTooltip('تظليل'));
      await _tap(t, find.byTooltip('تظليل'));
      await _stroke(t, const Offset(330, 260), const Offset(60, 262));
      await close();
      final s = await _saved(book.id);
      expect(s.strokes + s.items, greaterThanOrEqualTo(1));
    });
    await step('book: the menu offers export, written pages, marks, pages, tools, clean screen', () async {
      await open(book, wait: 3000);
      await _wake(t);
      await _tap(t, find.byTooltip('المزيد'));
      for (final s in ['الشاشة الصافية', 'تصدير ومشاركة', 'المكتوب عليها', 'العلامات', 'كل الصفحات']) {
        expect(find.text(s), findsWidgets, reason: s);
      }
      await _shot(t, '07_menu');
      await _tap(t, find.text('الشاشة الصافية'));
      expect(find.byTooltip('مربع الأدوات').hitTestable().evaluate(), isEmpty);
      expect(find.text('إعدادات الأدوات'), findsNothing);
    });
    await step('book: export sheet lists the five ways', () async {
      await _wake(t);
      await _tap(t, find.byTooltip('المزيد'));
      await _tap(t, find.text('تصدير ومشاركة'));
      expect(find.text('PDF: الكتاب كاملاً مع كتابتك'), findsOneWidget);
      expect(find.text('ملف نوتس (.nots)'), findsOneWidget);
      await _shot(t, '08_export');
      await _closeSheet(t);
    });

    await step('a template page is repeated into a note of several pages', () async {
      final src = await note();
      final bytes = await Paper.repeatPage(lib.pathOf(src), 3);
      final doc = await PdfDocument.openData(bytes, sourceName: 'repeat-check');
      expect(doc.pages.length, 3);
      await doc.dispose();
    });

    // ---- a blank page inside a book
    await step('book: a blank page is added inside it, kept, and moved', () async {
      await close();
      await open(book, wait: 3000);
      await _wake(t);
      await _tap(t, find.byTooltip('المزيد'));
      await _tap(t, find.text('إضافة صفحة فارغة هنا'));
      await _tap(t, find.text('إضافة الصفحة'));
      await _settle(t, 3000);
      expect(find.byType(ExtraPageTab), findsWidgets, reason: 'the added page is shown');
      await _shot(t, '11_added_page');
      await close();
      final pr = await ReaderPrefs.open(book.id);
      expect(pr.extras.length, 1);
      final id = pr.extras.single.id;
      pr.moveExtra(id, 8);
      await pr.flush();
      pr.dispose();
      await open(book, wait: 3000);
      final again = await ReaderPrefs.open(book.id);
      expect(again.extras.single.after, 8);
      again.dispose();
    });

    // ---- a note grows a page at a time
    await step('a note starts with one page; + adds the next', () async {
      await close();
      final n = await note();
      await open(n, wait: 3000);
      expect(find.textContaining('/ 1'), findsOneWidget);
      await _tap(t, find.byTooltip('صفحة جديدة'));
      await _settle(t, 2500);
      expect(find.textContaining('/ 2'), findsOneWidget);
      expect(notePageCount(await File(lib.pathOf(n)).readAsBytes()), 2);
    });

    // ---- a tablet
    await step('tablet: the bars fit one row and the page is wide', () async {
      await close();
      t.view.physicalSize = const Size(2388, 1668);
      await open(await note(), wait: 3000);
      final bars = t.getRect(find.byType(ReaderBars));
      expect(bars.height, lessThan(70), reason: 'one row: ${bars.height}');
      await _shot(t, '10_tablet');
    });

    // ignore: avoid_print
    print('\n=== RESULTS ===\n${_results.join('\n')}\n===============');
    expect(_failures, isEmpty, reason: _failures.join(', '));
  });
}
