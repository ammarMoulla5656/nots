import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/notes/text_note.dart';
import 'package:nots/notes/text_note_screen.dart';
import 'package:nots/ui/theme.dart';
import 'package:path/path.dart' as p;

const _screens = <String, Size>{
  'phone': Size(390, 844),
  'phone on its side': Size(844, 390),
  'tablet': Size(1180, 820),
  'narrow phone': Size(320, 640),
};

/// The platform's folders (the colour palette asks for one) are a temp one.
void _mockPlatform() {
  final dir = Directory.systemTemp.createTempSync('platform');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
}

Future<(LibraryStore, BookEntry)> _note() async {
  final root = await Directory.systemTemp.createTemp('textscreen');
  TextNoteStore.dirProvider = () async => Directory(p.join(root.path, 'docs'));
  InkStore.dirProvider = () async => Directory(p.join(root.path, 'ink'));
  final lib = await LibraryStore.openAt(root);
  final note = await createTextNote(lib, title: 'دروس الفقه');
  await TextNoteStore.write(note.id, [
    {'insert': 'كتاب الطهارة'},
    {
      'insert': '\n',
      'attributes': {'header': 1},
    },
    {'insert': 'نص عادي في الصفحة\n'},
  ]);
  return (lib, note);
}

Future<void> _show(
  WidgetTester t,
  Size size,
  LibraryStore lib,
  BookEntry note,
) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: TextNoteScreen(library: lib, book: note),
    ),
  );
  // The file and the drawing are read one after another, for real, away
  // from the test clock: let each finish, then show what it brought.
  for (var i = 0; i < 40 && find.byType(QuillEditor).evaluate().isEmpty; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
  await t.pump(const Duration(milliseconds: 100));
}

/// Takes the screen away and lets the clock run on: what it left running
/// (a blinking caret, the autosave) must end with it.
Future<void> _finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await t.pump(const Duration(seconds: 3));
}

void main() {
  for (final MapEntry(key: name, value: size) in _screens.entries) {
    testWidgets('$name: the editor, its toolbar and its bar fit', (t) async {
      _mockPlatform();
      final (lib, note) = (await t.runAsync(_note))!;
      await _show(t, size, lib, note);
      expect(find.byType(QuillEditor), findsOneWidget);
      expect(find.byType(QuillSimpleToolbar), findsOneWidget);
      // The editor draws its text as rich text.
      expect(
        find.textContaining('كتاب الطهارة', findRichText: true),
        findsWidgets,
      );
      expect(t.takeException(), isNull);

      // To drawing and back: the tools of drawing, then the toolbar again.
      await t.tap(find.byTooltip('وضع الرسم'));
      await t.pump();
      expect(find.byTooltip('قلم'), findsOneWidget);
      expect(find.byType(QuillSimpleToolbar), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('وضع الكتابة'));
      await t.pump();
      expect(find.byType(QuillSimpleToolbar), findsOneWidget);
      expect(t.takeException(), isNull);
      await _finish(t);
    });
  }

  testWidgets('the contents lists the headings; zoom does not break the page', (
    t,
  ) async {
    _mockPlatform();
    final (lib, note) = (await t.runAsync(_note))!;
    await _show(t, const Size(390, 844), lib, note);
    await t.tap(find.byTooltip('تكبير'));
    await t.pump();
    await t.tap(find.byTooltip('تصغير'));
    await t.pump();
    expect(t.takeException(), isNull);

    await t.tap(find.byTooltip('الفهرس'));
    await t.pumpAndSettle();
    // The heading is in the contents; no page number is shown beside it.
    expect(find.text('كتاب الطهارة'), findsWidgets);
    expect(find.text('ابحث في الفهرس'), findsOneWidget);
    // The sheet closes by a tap on the dimmed page.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await _finish(t);
  });

  // The pictures are compared with files made on the developer's computer
  // (the design folder is only there), like the screens test.
  final haveDesign = Directory('../des').existsSync();
  testWidgets('pictures of the text note', skip: !haveDesign, (t) async {
    await t.runAsync(() async {
      Future<void> load(String family, List<String> files) async {
        final l = FontLoader(family);
        for (final f in files) {
          l.addFont(
            Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
          );
        }
        await l.load();
      }

      await load('Muna', [
        for (final n in ['Regular', 'Bold', 'Black'])
          'assets/fonts/Muna-$n.ttf',
      ]);
      await load('Amiri', [
        'assets/fonts/Amiri-Regular.ttf',
        'assets/fonts/Amiri-Bold.ttf',
      ]);
      const icons =
          'C:/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
      if (File(icons).existsSync()) await load('MaterialIcons', [icons]);
    });
    _mockPlatform();
    final (lib, note) = (await t.runAsync(() async {
      final (l, n) = await _note();
      await TextNoteStore.write(n.id, [
        {'insert': 'دروس الفقه'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
        {'insert': 'كتاب الطهارة: '},
        {
          'insert': 'أحكام المياه',
          'attributes': {'bold': true, 'color': '#ff1c4f92'},
        },
        {'insert': ' والنجاسات وما يتعلق بها من مسائل.\n'},
        {
          'insert': 'نص بخط أميري وحجم أكبر',
          'attributes': {'font': 'Amiri', 'size': '24'},
        },
        {'insert': '\n'},
        {
          'insert': 'نص مظلّل بالأصفر',
          'attributes': {'background': '#ffffd54f'},
        },
        {'insert': '\n'},
        {'insert': 'الماء المطلق'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet'},
        },
        {'insert': 'الماء المضاف'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet'},
        },
        {'insert': 'الأحكام'},
        {
          'insert': '\n',
          'attributes': {'header': 2},
        },
        {'insert': 'يجب الغسل في موارد معينة تفصيلها في الرسالة العملية.\n'},
      ]);
      // A red line under the title and a circle round a word, by hand.
      final ink = await InkStore.open(n.id);
      StrokePoint pt(double x, double y, int i) =>
          StrokePoint(x, y, 0.5, i * 8);
      ink.document.add(
        1,
        Stroke(
          id: 1,
          tool: InkTool.pen,
          color: 0xFFC8372D,
          width: 2.2,
          points: [
            for (var i = 0; i <= 20; i++)
              pt(300 - i * 9.0, 70 + (i.isEven ? 1.5 : -1.5), i),
          ],
        ),
      );
      ink.document.add(
        1,
        Stroke(
          id: 2,
          tool: InkTool.pen,
          color: 0xFF0D47A1,
          width: 2.2,
          points: [
            for (var i = 0; i <= 36; i++)
              pt(
                330 + 60 * math.cos(i / 36 * 6.28),
                150 + 24 * math.sin(i / 36 * 6.28),
                i,
              ),
          ],
        ),
      );
      await ink.flush();
      await ink.dispose();
      return (l, n);
    }))!;
    await _show(t, const Size(390, 844), lib, note);
    await t.pump(const Duration(milliseconds: 300));
    Future<void> shot(String name) => expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../build/screens/$name.png'),
    );
    await shot('text_note');

    await t.tap(find.byTooltip('وضع الرسم'));
    await t.pump();
    await shot('text_note_draw');
    await t.tap(find.byTooltip('وضع الكتابة'));
    await t.pump();

    await t.tap(find.byTooltip('الفهرس'));
    await t.pumpAndSettle();
    await shot('text_note_contents');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();

    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('تصدير ومشاركة'));
    await t.pumpAndSettle();
    await shot('text_note_export');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await _finish(t);
  });
}
