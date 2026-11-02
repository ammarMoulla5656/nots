import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/note_items.dart';
import 'package:nots/ink/ruler.dart';
import 'package:nots/ink/page_ink_overlay.dart';
import 'package:nots/ink/selection.dart';
import 'package:nots/ink/shapes.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/ink/tool_controller.dart';
import 'package:nots/ink/words.dart';

class _Harness {
  _Harness(this.tester) {
    doc = InkDocument();
    tools = ToolController();
    selection = SelectionController(doc);
  }

  final WidgetTester tester;
  late final InkDocument doc;
  late final ToolController tools;
  late final SelectionController selection;
  final viewChanged = ChangeNotifier();
  List<WordBox> words = const [];
  final created = <(ItemKind, Offset)>[];
  final edited = <NoteItem>[];

  Future<void> pump() async {
    await tester.pumpWidget(MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 400,
          child: PageInkOverlay(
            document: doc,
            tools: tools,
            selection: selection,
            pageNumber: 1,
            pageWidthPt: 400,
            pageWidthPx: 400,
            viewChanged: viewChanged,
            onCreateItem: (page, kind, pt) async => created.add((kind, pt)),
            onEditItem: (page, item) async => edited.add(item),
            loadWords: () async => words,
          ),
        ),
      ),
    ));
  }

  Offset get origin => tester.getTopLeft(find.byType(PageInkOverlay));

  /// Draws a polyline with one pointer and lifts it.
  Future<void> drag(List<Offset> pts, {Duration hold = Duration.zero}) async {
    final o = origin;
    final g = await tester.startGesture(o + pts.first);
    for (final p in pts.skip(1)) {
      await g.moveTo(o + p);
    }
    if (hold > Duration.zero) await tester.pump(hold);
    await g.up();
    await tester.pump();
  }
}

void main() {
  testWidgets('pen: a drag becomes one stroke with the chosen tool and colour',
      (tester) async {
    final h = _Harness(tester);
    h.tools
      ..setMode(ToolMode.pen)
      ..setPenKind(InkTool.calligraphy)
      ..setColor(0xFFD32F2F);
    await h.pump();
    await h.drag(const [Offset(50, 50), Offset(90, 60), Offset(140, 90), Offset(200, 90)]);
    final s = h.doc.strokesOf(1).single;
    expect(s.tool, InkTool.calligraphy);
    expect(s.color, 0xFFD32F2F);
    expect(s.points.length, greaterThanOrEqualTo(4));
    expect(s.points.first.x, closeTo(50, 0.01));
  });

  testWidgets('hand tool draws nothing', (tester) async {
    final h = _Harness(tester);
    await h.pump();
    await h.drag(const [Offset(50, 50), Offset(150, 150)]);
    expect(h.doc.strokeCount, 0);
  });

  testWidgets('holding still at the end snaps a wobbly line straight',
      (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.pen);
    await h.pump();
    await h.drag(
      const [
        Offset(50, 100), Offset(80, 101), Offset(110, 99), Offset(140, 101),
        Offset(170, 100), Offset(200, 102), Offset(250, 100),
      ],
      hold: const Duration(milliseconds: 700),
    );
    expect(h.doc.strokesOf(1).single.points.length, 2);
  });

  testWidgets('moving on before the delay keeps the freehand stroke',
      (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.pen);
    await h.pump();
    await h.drag(const [
      Offset(50, 100), Offset(80, 101), Offset(110, 99), Offset(140, 101),
      Offset(170, 100), Offset(200, 102), Offset(250, 100),
    ]);
    expect(h.doc.strokesOf(1).single.points.length, 7);
  });

  testWidgets('snap can be turned off', (tester) async {
    final h = _Harness(tester);
    h.tools
      ..setMode(ToolMode.pen)
      ..setSnapShapes(false);
    await h.pump();
    await h.drag(
      const [Offset(50, 100), Offset(100, 101), Offset(150, 99), Offset(250, 100)],
      hold: const Duration(milliseconds: 700),
    );
    expect(h.doc.strokesOf(1).single.points.length, 4);
  });

  testWidgets('shape tool drags out a rectangle and ignores a bare tap',
      (tester) async {
    final h = _Harness(tester);
    h.tools
      ..setMode(ToolMode.shape)
      ..setShapeKind(ShapeKind.rectangle);
    await h.pump();
    await h.drag(const [Offset(60, 60), Offset(160, 140)]);
    final s = h.doc.strokesOf(1).single;
    expect(s.points.length, 5);
    expect(s.bounds.width, greaterThan(100));

    await h.drag(const [Offset(300, 300)]);
    expect(h.doc.strokesOf(1).length, 1);
  });

  testWidgets('eraser removes the stroke it crosses', (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.pen);
    await h.pump();
    await h.drag(const [Offset(50, 100), Offset(150, 100), Offset(250, 100)]);
    expect(h.doc.strokeCount, 1);

    h.tools.setMode(ToolMode.eraser);
    await tester.pump();
    await h.drag(const [Offset(150, 80), Offset(150, 120)]);
    expect(h.doc.strokeCount, 0);
    h.doc.undo();
    expect(h.doc.strokeCount, 1);
  });

  testWidgets('text and pin tools ask to create an item on a tap',
      (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.text);
    await h.pump();
    await h.drag(const [Offset(120, 80)]);
    h.tools.setMode(ToolMode.pin);
    await tester.pump();
    await h.drag(const [Offset(220, 180)]);

    expect(h.created.map((e) => e.$1), [ItemKind.text, ItemKind.pin]);
    expect(h.created[0].$2.dx, closeTo(120, 0.01));
    expect(h.created[1].$2.dy, closeTo(180, 0.01));

    // Dragging over empty page is not a tap and creates nothing.
    h.tools.setMode(ToolMode.text);
    await tester.pump();
    await h.drag(const [Offset(20, 20), Offset(80, 90)]);
    expect(h.created.length, 2);
  });

  testWidgets('first tap selects an item, tapping it again edits it',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(id: 1, kind: ItemKind.pin, x: 200, y: 200, text: 'n'),
    );
    h.tools.setMode(ToolMode.pin);
    await h.pump();

    await h.drag(const [Offset(200, 200)]);
    expect(h.selection.itemId, 1);
    expect(h.edited, isEmpty);

    await h.drag(const [Offset(200, 200)]);
    expect(h.edited.single.id, 1);
  });

  testWidgets('dragging an item moves it and keeps it selected',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(id: 1, kind: ItemKind.pin, x: 200, y: 200, text: 'n'),
    );
    h.tools.setMode(ToolMode.pin);
    await h.pump();

    await h.drag(const [Offset(200, 200), Offset(230, 240)]);
    final moved = h.doc.itemsOf(1).single;
    expect(moved.x, closeTo(230, 0.01));
    expect(moved.y, closeTo(240, 0.01));
    expect(h.edited, isEmpty);
    expect(h.selection.itemId, 1);
    h.doc.undo();
    expect(h.doc.itemsOf(1).single.x, closeTo(200, 0.01));
  });

  testWidgets('the X button deletes the selected item, undo brings it back',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(
          id: 1, kind: ItemKind.text, x: 100, y: 100, w: 220, text: 'hello'),
    );
    h.tools.setMode(ToolMode.text);
    await h.pump();
    await h.drag(const [Offset(150, 105)]);
    expect(h.selection.itemId, 1);

    final geo = SelectionGeometry(h.selection.bounds!, 1,
        canEdit: true, canResize: true);
    await h.drag([geo.closeCenter]);
    expect(h.doc.itemsOf(1), isEmpty);
    expect(h.selection.active, isFalse);
    h.doc.undo();
    expect(h.doc.itemsOf(1).single.id, 1);
  });

  testWidgets('the pencil button asks to edit the selected text',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(
          id: 1, kind: ItemKind.text, x: 100, y: 100, w: 220, text: 'hello'),
    );
    h.tools.setMode(ToolMode.text);
    await h.pump();
    await h.drag(const [Offset(150, 105)]);
    final geo = SelectionGeometry(h.selection.bounds!, 1,
        canEdit: true, canResize: true);
    await h.drag([geo.editCenter]);
    expect(h.edited.single.id, 1);
  });

  testWidgets('dragging a corner handle scales the text size',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(
          id: 1,
          kind: ItemKind.text,
          x: 100,
          y: 100,
          w: 120,
          text: 'hello',
          fontSize: 14),
    );
    h.tools.setMode(ToolMode.text);
    await h.pump();
    await h.drag(const [Offset(150, 105)]);

    final geo = SelectionGeometry(h.selection.bounds!, 1,
        canEdit: true, canResize: true);
    final grab = geo.corners[2]; // bottom-right
    final anchor = geo.anchorFor(2); // top-left of the text
    await h.drag([grab, anchor + (grab - anchor) * 1.5]);

    final it = h.doc.itemsOf(1).single;
    expect(it.fontSize, closeTo(21, 0.1));
    expect(it.w, closeTo(180, 0.5));
    expect(it.x, closeTo(100, 0.01)); // the anchor corner stayed put
    expect(it.y, closeTo(100, 0.01));

    // and back down again
    final geo2 = SelectionGeometry(h.selection.bounds!, 1,
        canEdit: true, canResize: true);
    final grab2 = geo2.corners[2];
    await h.drag([grab2, anchor + (grab2 - anchor) / 1.5]);
    expect(h.doc.itemsOf(1).single.fontSize, closeTo(14, 0.2));
    h.doc.undo();
    expect(h.doc.itemsOf(1).single.fontSize, closeTo(21, 0.1));
  });

  testWidgets('tape can be stretched with a handle', (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(
          id: 1, kind: ItemKind.tape, x: 50, y: 50, w: 100, h: 20, color: 0xFF333333),
    );
    h.tools.setMode(ToolMode.lasso);
    await h.pump();
    await h.drag(const [Offset(100, 60)]); // tap picks the tape
    expect(h.selection.itemId, 1);

    final geo = SelectionGeometry(h.selection.bounds!, 1,
        canEdit: false, canResize: true);
    await h.drag([geo.corners[2], const Offset(250, 120)]);
    final t = h.doc.itemsOf(1).single;
    expect(t.x, closeTo(50, 0.01));
    expect(t.w, closeTo(200, 0.01));
    expect(t.h, closeTo(70, 0.01));
  });

  testWidgets('lasso tap picks a stroke; X deletes it; handle resizes it',
      (tester) async {
    final h = _Harness(tester);
    h.tools
      ..setMode(ToolMode.pen)
      ..setSnapShapes(false);
    await h.pump();
    await h.drag(const [Offset(100, 100), Offset(160, 100), Offset(160, 140)]);
    final width0 = h.doc.strokesOf(1).single.width;

    h.tools.setMode(ToolMode.lasso);
    await tester.pump();
    await h.drag(const [Offset(130, 101)]); // a tap right on the line
    expect(h.selection.ids.length, 1);

    // resize to 2x from the bottom-right handle
    final geo = SelectionGeometry(h.selection.bounds!, 1,
        canEdit: false, canResize: true);
    final grab = geo.corners[2];
    final anchor = geo.anchorFor(2);
    await h.drag([grab, anchor + (grab - anchor) * 2]);
    final s = h.doc.strokesOf(1).single;
    expect(s.width, closeTo(width0 * 2, 0.01));
    expect(s.points.first.x, closeTo(100 - (anchor.dx - 100) * 0 + (100 - anchor.dx), 0.5));
    expect(s.bounds.width, greaterThan(100));
    h.doc.undo();
    expect(h.doc.strokesOf(1).single.width, closeTo(width0, 0.001));
    h.doc.redo();

    final geo2 = SelectionGeometry(h.selection.bounds!, 1,
        canEdit: false, canResize: false);
    await h.drag([geo2.closeCenter]);
    expect(h.doc.strokeCount, 0);
  });

  testWidgets('a finger landing on another page cancels the stroke here',
      (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.pen);
    await h.pump();
    final o = h.origin;

    final a = await tester.startGesture(o + const Offset(50, 50));
    await a.moveTo(o + const Offset(90, 70));
    // The viewer-wide navigator saw a second finger elsewhere.
    h.tools.setMultiTouch(true);
    await a.moveTo(o + const Offset(140, 90));
    await a.up();
    await tester.pump();
    expect(h.doc.strokeCount, 0);

    // While fingers are still down nothing draws...
    await h.drag(const [Offset(50, 150), Offset(150, 150)]);
    expect(h.doc.strokeCount, 0);
    // ...and once they are all lifted drawing works again.
    h.tools.setMultiTouch(false);
    await tester.pump();
    await h.drag(const [Offset(50, 150), Offset(150, 150)]);
    expect(h.doc.strokeCount, 1);
  });

  testWidgets('with finger drawing off only the pen writes', (tester) async {
    final h = _Harness(tester);
    h.tools
      ..setMode(ToolMode.pen)
      ..setFingerDraws(false);
    await h.pump();
    final o = h.origin;

    // A finger never writes (it is left to the navigator, which scrolls).
    await h.drag(const [Offset(50, 300), Offset(150, 300)]);
    expect(h.doc.strokeCount, 0);
    expect(h.tools.fingerScrolls, isTrue);

    final pen = await tester.startGesture(o + const Offset(50, 50),
        kind: PointerDeviceKind.stylus);
    await pen.moveTo(o + const Offset(150, 50));
    await pen.up();
    await tester.pump();
    expect(h.doc.strokeCount, 1);

    await h.drag(const [Offset(50, 200), Offset(150, 200)]);
    expect(h.doc.strokeCount, 1);

    // Switched back on, the finger writes again.
    h.tools.setFingerDraws(true);
    await h.drag(const [Offset(50, 200), Offset(150, 200)]);
    expect(h.doc.strokeCount, 2);
  });

  testWidgets('a pen button erases; notes and commented words survive',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(1, const NoteItem(id: 1, kind: ItemKind.pin, x: 100, y: 100, text: 'n'));
    h.doc.addItem(1, const NoteItem(id: 2, kind: ItemKind.tape, x: 100, y: 150, w: 100, h: 20));
    h.doc.addItem(1, NoteItem.mark(
        id: 3, lineRects: const [Rect.fromLTWH(100, 200, 60, 14)],
        style: MarkStyle.comment, color: 0xFFEF6C00, comment: 'تعليق'));
    h.doc.addItem(1, NoteItem.mark(
        id: 4, lineRects: const [Rect.fromLTWH(100, 250, 60, 14)],
        style: MarkStyle.highlight, color: 0xFFFFEB3B));
    h.tools.setMode(ToolMode.eraser);
    await h.pump();
    // Swipe the eraser across everything.
    await h.drag(const [Offset(90, 90), Offset(90, 300), Offset(180, 300),
        Offset(180, 90)]);
    await h.drag(const [Offset(95, 105), Offset(210, 105), Offset(210, 160),
        Offset(95, 160), Offset(95, 210), Offset(170, 210), Offset(170, 258), Offset(95, 258)]);
    final left = h.doc.itemsOf(1).map((e) => e.id).toSet();
    expect(left, {1, 3}); // pin and commented word stay; tape and plain mark go
  });

  testWidgets('word tool: tap marks one word, drag marks a range of words',
      (tester) async {
    final h = _Harness(tester);
    h.words = const [
      // two words on line 1 (right to left), one on line 2
      WordBox(0, 4, 'كلمة', Rect.fromLTWH(200, 100, 60, 14)),
      WordBox(5, 9, 'ثانية', Rect.fromLTWH(120, 100, 70, 14)),
      WordBox(10, 15, 'ثالثة', Rect.fromLTWH(200, 130, 60, 14)),
    ];
    h.tools
      ..setMode(ToolMode.word)
      ..setMarkStyle(MarkStyle.underline)
      ..setColor(0xFFD32F2F);
    await h.pump();
    await tester.pump(); // let the word list load

    await h.drag(const [Offset(230, 107)]);
    final one = h.doc.itemsOf(1).single;
    expect(one.kind, ItemKind.mark);
    expect(one.style, MarkStyle.underline);
    expect(one.color, 0xFFD32F2F);
    expect(one.quote, 'كلمة');
    expect(one.rects.single, const Rect.fromLTWH(200, 100, 60, 14));

    // Drag from the second word to the word on the next line.
    await h.drag(const [Offset(150, 107), Offset(180, 120), Offset(230, 137)]);
    final range = h.doc.itemsOf(1).last;
    expect(range.quote, 'ثانية ثالثة');
    expect(range.rects.length, 2); // one rectangle per line

    // Tapping an already marked word selects its mark instead of marking again.
    await h.drag(const [Offset(230, 107)]);
    expect(h.doc.itemsOf(1).length, 2);
    expect(h.selection.itemId, one.id);

    // Tapping a mark selects it (marks never move).
    await h.drag(const [Offset(230, 137), Offset(300, 300)]);
    expect(h.selection.itemId, range.id);
    expect(h.doc.itemsOf(1).last.x, range.x);
  });

  testWidgets('tape: drag adds a strip, tap toggles it, eraser removes it',
      (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.tape);
    await h.pump();
    await h.drag(const [Offset(50, 50), Offset(250, 80)]);
    final tape = h.doc.itemsOf(1).single;
    expect(tape.kind, ItemKind.tape);
    expect(tape.w, closeTo(200, 0.01));
    expect(tape.h, closeTo(30, 0.01));
    expect(tape.revealed, isFalse);

    await h.drag(const [Offset(100, 60)]);
    expect(h.doc.itemsOf(1).single.revealed, isTrue);
    await h.drag(const [Offset(100, 60)]);
    expect(h.doc.itemsOf(1).single.revealed, isFalse);

    h.tools.setMode(ToolMode.eraser);
    await tester.pump();
    await h.drag(const [Offset(100, 60), Offset(110, 60)]);
    expect(h.doc.itemsOf(1), isEmpty);
  });

  testWidgets('a second finger cancels the stroke the first one started',
      (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.pen);
    await h.pump();
    final o = h.origin;
    final a = await tester.startGesture(o + const Offset(50, 50));
    await a.moveTo(o + const Offset(80, 80));
    final b = await tester.startGesture(o + const Offset(300, 300));
    await a.moveTo(o + const Offset(120, 120));
    await a.up();
    await b.up();
    await tester.pump();
    expect(h.doc.strokeCount, 0);

    // Input works again once every finger is up.
    await h.drag(const [Offset(50, 50), Offset(150, 150)]);
    expect(h.doc.strokeCount, 1);
  });

  testWidgets('lasso selects, moves and recolours what it surrounds',
      (tester) async {
    final h = _Harness(tester);
    h.tools.setMode(ToolMode.pen);
    await h.pump();
    await h.drag(const [Offset(100, 100), Offset(140, 100)]);

    h.tools.setMode(ToolMode.lasso);
    await tester.pump();
    await h.drag(const [
      Offset(80, 80), Offset(170, 80), Offset(170, 130), Offset(80, 130), Offset(80, 82),
    ]);
    expect(h.selection.active, isTrue);

    await h.drag(const [Offset(120, 100), Offset(150, 160)]);
    expect(h.doc.strokesOf(1).single.points.first.x, closeTo(130, 0.01));
    expect(h.doc.strokesOf(1).single.points.first.y, closeTo(160, 0.01));
    expect(h.selection.active, isTrue);

    // Tapping empty space clears the selection.
    await h.drag(const [Offset(350, 350)]);
    expect(h.selection.active, isFalse);
  });

  // pdfrx stacks page overlays ABOVE its pan/zoom area (siblings, not
  // children). Anything hit-testable in the overlay therefore steals the
  // touch from the viewer: in the hand tool the page could not be moved or
  // zoomed inside the page, only outside it.
  testWidgets('hand tool: touches pass through the overlay to the viewer',
      (tester) async {
    final doc = InkDocument();
    doc.addItem(1, const NoteItem(id: 1, kind: ItemKind.text, x: 10, y: 10, w: 200, text: 'نص'));
    doc.add(1, Stroke(id: 2, tool: InkTool.pen, color: 0xFF000000, width: 3,
        points: const [StrokePoint(50, 100, 0.5, 0), StrokePoint(300, 100, 0.5, 9)]));
    final tools = ToolController();
    final selection = SelectionController(doc);
    var viewerDrags = 0;
    await tester.pumpWidget(MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 400,
          child: Stack(children: [
            // stands in for pdfrx's InteractiveViewer
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (_) => viewerDrags++,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned.fill(
              child: PageInkOverlay(
                document: doc,
                tools: tools,
                selection: selection,
                pageNumber: 1,
                pageWidthPt: 400,
                pageWidthPx: 400,
                viewChanged: ChangeNotifier(),
                onCreateItem: (_, _, _) async {},
                onEditItem: (_, _) async {},
              ),
            ),
          ]),
        ),
      ),
    ));

    // On the text box, on the stroke, and on empty page: the viewer moves.
    for (final at in const [Offset(30, 20), Offset(150, 100), Offset(200, 300)]) {
      final before = viewerDrags;
      await tester.dragFrom(at, const Offset(0, -120));
      await tester.pump();
      expect(viewerDrags, greaterThan(before), reason: 'drag at $at');
    }

    // With a drawing tool the overlay takes the single finger instead.
    tools.setMode(ToolMode.pen);
    await tester.pump();
    final before = viewerDrags;
    await tester.dragFrom(const Offset(200, 300), const Offset(0, -120));
    await tester.pump();
    expect(viewerDrags, before);
    expect(doc.strokeCount, 2);
  });

  testWidgets('highlighter over text becomes a word highlight; over blank page '
      'it stays a free stroke', (tester) async {
    final h = _Harness(tester);
    h.words = const [
      WordBox(0, 4, 'كلمة', Rect.fromLTWH(200, 100, 60, 14)),
      WordBox(5, 9, 'ثانية', Rect.fromLTWH(120, 100, 70, 14)),
    ];
    h.tools.setMode(ToolMode.highlighter);
    await h.pump();
    await tester.pump();

    await h.drag(const [Offset(270, 107), Offset(150, 107), Offset(110, 107)]);
    final mark = h.doc.itemsOf(1).single;
    expect(mark.kind, ItemKind.mark);
    expect(mark.style, MarkStyle.highlight);
    expect(mark.quote, 'كلمة ثانية');
    expect(h.doc.strokeCount, 0);

    await h.drag(const [Offset(50, 300), Offset(300, 300)]);
    expect(h.doc.itemsOf(1).length, 1);
    expect(h.doc.strokeCount, 1);
  });

  testWidgets('ruler: a stroke along its edge is a straight line; the body moves it',
      (tester) async {
    final h = _Harness(tester);
    h.tools.ruler.value =
        const Ruler(page: 1, center: Offset(200, 200), length: 300, thickness: 50);
    h.tools
      ..setMode(ToolMode.pen)
      ..setSnapShapes(false);
    await h.pump();

    // bottom edge is y = 225; start close to it and wobble
    await h.drag(const [Offset(100, 227), Offset(150, 240), Offset(220, 215), Offset(300, 223)]);
    final s = h.doc.strokesOf(1).single;
    expect(s.points.length, 2);
    expect(s.points.first.y, closeTo(225, 1e-6));
    expect(s.points.last.y, closeTo(225, 1e-6));
    expect(s.points.last.x, closeTo(300, 1e-6));

    // dragging the middle of the ruler moves it and draws nothing
    await h.drag(const [Offset(200, 200), Offset(230, 260)]);
    final r = h.tools.ruler.value!;
    expect(r.center.dx, closeTo(230, 1e-6));
    expect(r.center.dy, closeTo(260, 1e-6));
    expect(h.doc.strokeCount, 1);
  });

  testWidgets('two fingers inside the selection frame scale it, not the page',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(
          id: 1, kind: ItemKind.text, x: 100, y: 100, w: 120, text: 'hello world', fontSize: 14),
    );
    h.tools.setMode(ToolMode.text);
    await h.pump();
    await h.drag(const [Offset(110, 105)]); // select it
    expect(h.selection.itemId, 1);
    final b = h.selection.bounds!;
    final o = h.origin;

    final a = await tester.startGesture(o + Offset(b.left + 4, b.center.dy));
    final c = await tester.startGesture(o + Offset(b.right - 4, b.center.dy));
    expect(h.tools.selectionPinch, isTrue);
    expect(h.tools.multiTouch, isFalse);
    await a.moveBy(const Offset(-30, 0));
    await c.moveBy(const Offset(30, 0));
    await a.up();
    await c.up();
    await tester.pump();

    final it = h.doc.itemsOf(1).single;
    expect(it.fontSize, greaterThan(14 * 1.4));
    expect(h.tools.selectionPinch, isFalse);
  });

  testWidgets('eraser: a tap does not delete a tape strip, a drag does',
      (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(1, const NoteItem(id: 1, kind: ItemKind.tape, x: 100, y: 100, w: 150, h: 20));
    h.tools.setMode(ToolMode.eraser);
    await h.pump();
    await h.drag(const [Offset(150, 110)]);
    expect(h.doc.itemsOf(1), hasLength(1));
    await h.drag(const [Offset(110, 110), Offset(240, 110)]);
    expect(h.doc.itemsOf(1), isEmpty);
  });
}
