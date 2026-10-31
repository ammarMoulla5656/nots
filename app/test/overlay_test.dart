import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/note_items.dart';
import 'package:nots/ink/page_ink_overlay.dart';
import 'package:nots/ink/selection.dart';
import 'package:nots/ink/shapes.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/ink/tool_controller.dart';

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
            onCreateItem: (page, kind, pt) async => created.add((kind, pt)),
            onEditItem: (page, item) async => edited.add(item),
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

  testWidgets('tapping an item edits it, dragging moves it', (tester) async {
    final h = _Harness(tester);
    h.doc.addItem(
      1,
      const NoteItem(id: 1, kind: ItemKind.pin, x: 200, y: 200, text: 'n'),
    );
    h.tools.setMode(ToolMode.pin);
    await h.pump();

    await h.drag(const [Offset(200, 200)]);
    expect(h.edited.single.id, 1);

    await h.drag(const [Offset(200, 200), Offset(230, 240)]);
    final moved = h.doc.itemsOf(1).single;
    expect(moved.x, closeTo(230, 0.01));
    expect(moved.y, closeTo(240, 0.01));
    expect(h.edited.length, 1);
    h.doc.undo();
    expect(h.doc.itemsOf(1).single.x, closeTo(200, 0.01));
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
}
