import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/marks.dart';
import 'package:nots/ink/note_items.dart';
import 'package:nots/ink/words.dart';
import 'package:nots/reader/selection_menu.dart';
import 'package:nots/ui/color_palette.dart';

const _red = 0xFFD32F2F, _green = 0xFF2E7D32;

/// The button of colour [c].
Finder _dot(int c) => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).color == Color(c),
);

NoteItem _mark(
  int id,
  Rect r,
  int color, {
  MarkStyle style = MarkStyle.textColor,
}) => NoteItem.mark(id: id, lineRects: [r], style: style, color: color);

void main() {
  group('ColorPalette', () {
    test('a new colour goes first, once; removing never empties the list', () {
      final p = ColorPalette(colors: const [_red]);
      p.add(_green);
      p.add(_green);
      expect(p.colors, [_green, _red]);
      p.remove(_green);
      p.remove(_red);
      expect(p.colors, [_red]);
    });

    test('never more than four colours: a new one pushes out the last', () {
      final p = ColorPalette();
      expect(p.colors.length, ColorPalette.maxColors);
      final last = p.colors.last;
      p.setMarkColor(last);
      p.add(_green);
      expect(p.colors.length, ColorPalette.maxColors);
      expect(p.colors.first, _green);
      expect(p.colors, isNot(contains(last)));
      expect(p.markColor, _green);
      final q = ColorPalette()..restore('{"colors":[1,2,3,4,5,6]}');
      expect(q.colors, [1, 2, 3, 4]);
    });

    test('removing the mark colour moves on to one still on the list', () {
      final p = ColorPalette(colors: const [_red, _green], markColor: _green);
      p.remove(_green);
      expect(p.markColor, _red);
    });

    test('added colours and the last mark colour are restored', () {
      final p = ColorPalette(colors: const [_red])
        ..add(_green)
        ..setMarkColor(_green);
      final q = ColorPalette()..restore(p.encode());
      expect(q.colors, [_green, _red]);
      expect(q.markColor, _green);
    });
  });

  group('SelectionMenu', () {
    Future<List<int?>> pump(WidgetTester tester, ColorPalette palette) async {
      final pressed = <int?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionMenu(
                palette: palette,
                actions: [(label: 'لون الخط', onPressed: pressed.add)],
              ),
            ),
          ),
        ),
      );
      return pressed;
    }

    testWidgets('the picked colour goes to the action pressed next', (
      tester,
    ) async {
      final pressed = await pump(
        tester,
        ColorPalette(colors: const [_red, _green]),
      );
      await tester.tap(find.text('لون الخط'));
      await tester.tap(_dot(_green));
      await tester.pump();
      await tester.tap(find.text('لون الخط'));
      expect(pressed, [null, _green]);
    });

    testWidgets('a long press takes a colour off the list', (tester) async {
      final palette = ColorPalette(colors: const [_red, _green]);
      await pump(tester, palette);
      await tester.longPress(_dot(_green));
      await tester.pump();
      expect(palette.colors, [_red]);
      expect(_dot(_green), findsNothing);
    });

    testWidgets('"+" adds a colour from the wheel and picks it', (
      tester,
    ) async {
      // The wheel opens on the current colour, which is not on the list yet.
      final palette = ColorPalette(colors: const [_red], markColor: _green);
      final pressed = await pump(tester, palette);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('موافق'));
      await tester.pumpAndSettle();
      expect(palette.colors.length, 2);
      await tester.tap(find.text('لون الخط'));
      expect(pressed, [palette.colors.first]);
    });
  });

  group('applyMark', () {
    const words = Rect.fromLTWH(100, 100, 200, 20);

    test('another colour on the same words replaces the mark, in one step', () {
      final doc = InkDocument();
      applyMark(doc, 1, _mark(1, words, _red));
      applyMark(doc, 1, _mark(2, words, _green));
      expect(doc.itemsOf(1).single.color, _green);
      doc.undo();
      expect(doc.itemsOf(1).single.color, _red);
    });

    test('the same colour on the same words takes the mark off', () {
      final doc = InkDocument();
      applyMark(doc, 1, _mark(1, words, _red));
      applyMark(doc, 1, _mark(2, words, _red));
      expect(doc.itemsOf(1), isEmpty);
    });

    test('a word recoloured inside a sentence leaves the rest as it was', () {
      final doc = InkDocument();
      applyMark(doc, 1, _mark(1, words, _red));
      applyMark(
        doc,
        1,
        _mark(2, const Rect.fromLTWH(180, 100, 40, 20), _green),
      );
      final items = doc.itemsOf(1);
      expect(items.map((e) => e.color), [_red, _green]);
      expect(items.first.rects, const [
        Rect.fromLTRB(100, 100, 180, 120),
        Rect.fromLTRB(220, 100, 300, 120),
      ]);
    });

    test('marks of another style are left alone', () {
      final doc = InkDocument();
      applyMark(doc, 1, _mark(1, words, _red, style: MarkStyle.underline));
      applyMark(doc, 1, _mark(2, words, _red));
      expect(doc.itemsOf(1).length, 2);
    });
  });

  test('rectsMinus cuts only on the line it crosses and drops slivers', () {
    const lines = [Rect.fromLTWH(0, 0, 100, 10), Rect.fromLTWH(0, 20, 100, 10)];
    expect(rectsMinus(lines, const [Rect.fromLTWH(-1, 0, 102, 10)]), [
      lines[1],
    ]);
    expect(rectsMinus(lines, const [Rect.fromLTWH(1, 20, 50, 10)]), [
      lines[0],
      const Rect.fromLTRB(51, 20, 100, 30),
    ]);
  });
}
