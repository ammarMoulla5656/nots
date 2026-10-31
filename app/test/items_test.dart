import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/note_items.dart';
import 'package:nots/ink/stroke.dart';

NoteItem _text(int id, String text) => NoteItem(
      id: id,
      kind: ItemKind.text,
      x: 12.34,
      y: 56.78,
      w: 220,
      text: text,
      color: 0xFF1565C0,
      fontSize: 14,
    );

void main() {
  test('items survive a save/load round trip, including Arabic text', () {
    final items = {
      3: [
        _text(1, 'قال الشيخ: هذا هو الصحيح — and some English'),
        const NoteItem(
            id: 2, kind: ItemKind.pin, x: 100, y: 200, text: 'ملاحظة', color: 0xFFEF6C00),
        const NoteItem(
            id: 4,
            kind: ItemKind.tape,
            x: 10,
            y: 20,
            w: 150.5,
            h: 18.25,
            color: 0xFF333333,
            revealed: true),
      ],
    };
    final bytes = StrokeCodec.encodeDocument({}, 5, items: items);
    final back = StrokeCodec.decodeDocument(bytes);

    expect(back.nextStrokeId, 5);
    final list = back.items[3]!;
    expect(list.length, 3);
    expect(list[0].text, items[3]![0].text);
    expect(list[0].x, closeTo(12.34, 0.005));
    expect(list[0].fontSize, closeTo(14, 0.005));
    expect(list[1].kind, ItemKind.pin);
    expect(list[1].text, 'ملاحظة');
    expect(list[2].kind, ItemKind.tape);
    expect(list[2].revealed, isTrue);
    expect(list[2].w, closeTo(150.5, 0.005));
    expect(list[2].h, closeTo(18.25, 0.005));
  });

  test('files written by version 1 (strokes only) still open', () {
    // "NOTS", version 1, nextStrokeId 7, zero pages.
    final v1 = Uint8List.fromList([0x4E, 0x4F, 0x54, 0x53, 1, 7, 0]);
    final back = StrokeCodec.decodeDocument(v1);
    expect(back.nextStrokeId, 7);
    expect(back.pages, isEmpty);
    expect(back.items, isEmpty);
  });

  test('every ink tool survives a round trip', () {
    final pages = {
      1: [
        for (final (i, t) in InkTool.values.indexed)
          Stroke(
            id: i + 1,
            tool: t,
            color: 0xFF000000,
            width: 2,
            points: const [StrokePoint(1, 1, 0.5, 0), StrokePoint(5, 5, 0.5, 4)],
          ),
      ],
    };
    final back = StrokeCodec.decodeDocument(StrokeCodec.encodeDocument(pages, 9));
    expect(back.pages[1]!.map((s) => s.tool), InkTool.values);
  });

  group('InkDocument items', () {
    test('add, move, edit and remove are all undoable', () {
      final d = InkDocument();
      d.addItem(1, _text(d.takeStrokeId(), 'a'));
      d.replaceItem(1, d.itemsOf(1).first.copyWith(x: 99));
      d.replaceItem(1, d.itemsOf(1).first.copyWith(text: 'b'));
      d.removeItem(1, d.itemsOf(1).first.id);
      expect(d.itemsOf(1), isEmpty);

      d.undo(); // un-remove
      expect(d.itemsOf(1).single.text, 'b');
      d.undo(); // un-edit
      expect(d.itemsOf(1).single.text, 'a');
      expect(d.itemsOf(1).single.x, 99);
      d.undo(); // un-move
      expect(d.itemsOf(1).single.x, closeTo(12.34, 1e-9));
      d.undo(); // un-add
      expect(d.itemsOf(1), isEmpty);

      d.redo();
      d.redo();
      expect(d.itemsOf(1).single.x, 99);
    });

    test('items and strokes share one undo history', () {
      final d = InkDocument();
      d.add(1, Stroke(id: d.takeStrokeId(), tool: InkTool.pen, color: 0xFF000000, width: 1,
          points: const [StrokePoint(0, 0, 0.5, 0)]));
      d.addItem(1, _text(d.takeStrokeId(), 'x'));
      d.undo();
      expect(d.itemsOf(1), isEmpty);
      expect(d.strokesOf(1).length, 1);
      d.undo();
      expect(d.strokesOf(1), isEmpty);
    });
  });

  test('isRtlText follows the first strong letter', () {
    expect(isRtlText('مرحبا hello'), isTrue);
    expect(isRtlText('hello مرحبا'), isFalse);
    expect(isRtlText('123 — مرحبا'), isTrue);
    expect(isRtlText('1234'), isFalse);
  });
}
