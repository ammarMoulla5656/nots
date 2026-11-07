// Runs the reader for real (with pdfium) on a desktop and takes pictures of
// it into build/screens/. flutter test integration_test/reader_test.dart -d windows
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/notes/note_pdf.dart';
import 'package:nots/notes/paper.dart';
import 'package:nots/reader/reader_chrome.dart';
import 'package:nots/ui/brand_widgets.dart';
import 'package:nots/reader/reader_prefs.dart';
import 'package:nots/reader/reader_screen.dart';
import 'package:nots/reader/tool_layout.dart';
import 'package:nots/book/book_link_store.dart';
import 'package:nots/sync/conflicts.dart';
import 'package:nots/ui/app_settings.dart';
import 'package:nots/ui/theme.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

final _key = GlobalKey();

Future<void> _settle(WidgetTester t, [int ms = 900]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  await _settle(t, 300);
  final b = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await b.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File('build/screens/$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.tap(f.first);
  await _settle(t, 500);
}

Future<void> _stroke(WidgetTester t, Offset from, Offset to) async {
  final g = await t.startGesture(from);
  for (var i = 1; i <= 12; i++) {
    await g.moveTo(Offset.lerp(from, to, i / 12)! + Offset(0, (i % 3) * 3.0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await _settle(t, 300);
}

/// After writing the bars are away: the small round button brings them back.
Future<void> _wake(WidgetTester t) async {
  if (find.byType(ToolDot).evaluate().isNotEmpty) {
    await t.tap(find.byType(ToolDot).first);
    await _settle(t, 500);
  }
}

/// Closes the sheet on top.
Future<void> _close(WidgetTester t) async {
  final h = find.byType(SheetHeader);
  if (h.evaluate().isEmpty) return;
  Navigator.of(t.element(h.last)).pop();
  await _settle(t, 500);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the reader, on a phone and on a tablet', (t) async {
    await pdfrxFlutterInitialize();
    final root = await Directory.systemTemp.createTemp('nots_reader_');
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
    final note = await createNote(
      lib,
      const PaperStyle(kind: PaperKind.lined, paper: 0xFFFFF4CC, line: 0xFFC8372D),
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

    // ---- a phone
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(book));
    await _settle(t, 3500);
    await _shot(t, 'reader_1_open');

    await _tap(t, find.byTooltip('قلم'));
    await _shot(t, 'reader_2_pen_options');

    await _tap(t, find.byTooltip('مربع الأدوات'));
    await _shot(t, 'reader_3_box');

    await _tap(t, find.text('ليزر'));
    await _stroke(t, const Offset(300, 500), const Offset(100, 600));
    await _wake(t);

    await _tap(t, find.byTooltip('مربع الأدوات'));
    await _tap(t, find.text('إعدادات الأدوات'));
    await _shot(t, 'reader_4_tool_settings');
    await _tap(t, find.text('تم'));
    await _wake(t);

    await _tap(t, find.byTooltip('قلم'));
    await _tap(t, find.byTooltip('قلم')); // closes the options
    await _stroke(t, const Offset(260, 420), const Offset(80, 440));
    await _stroke(t, const Offset(250, 470), const Offset(90, 480));
    await _shot(t, 'reader_5_writing_clean');
    await _wake(t);
    await _shot(t, 'reader_5b_bars_back');

    await _tap(t, find.byTooltip('الفهرس'));
    await _shot(t, 'reader_6_contents');
    await _close(t);

    await _tap(t, find.byTooltip('المزيد'));
    await _shot(t, 'reader_7_menu');
    await _tap(t, find.text('المكتوب عليها'));
    await _shot(t, 'reader_8_written_pages');
    await _close(t);

    await _tap(t, find.byTooltip('وضع علامة على الصفحة'));
    await _shot(t, 'reader_9_bookmark');

    // ---- a note
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(note));
    await _settle(t, 2500);
    await _tap(t, find.byTooltip('قلم'));
    await _tap(t, find.byTooltip('قلم'));
    await _stroke(t, const Offset(300, 520), const Offset(90, 560));
    await _shot(t, 'reader_10_note');

    // ---- a tablet
    t.view.physicalSize = const Size(2388, 1668);
    t.view.devicePixelRatio = 2;
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(book));
    await _settle(t, 3500);
    await _shot(t, 'reader_11_tablet');
    await _tap(t, find.byTooltip('قلم'));
    await _shot(t, 'reader_12_tablet_pen');
  });
}
