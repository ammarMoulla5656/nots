import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/stroke.dart';

Stroke _stroke(int id, List<StrokePoint> pts,
        {InkTool tool = InkTool.pen, int color = 0xFFD32F2F, double width = 1.6}) =>
    Stroke(id: id, tool: tool, color: color, width: width, points: pts);

void main() {
  group('StrokeCodec', () {
    test('round trip keeps geometry within 0.005 pt, pressure and time', () {
      final original = {
        1: [
          _stroke(1, const [
            StrokePoint(10.123, 20.456, 0.0, 0),
            StrokePoint(10.9, 19.0, 0.5, 8),
            StrokePoint(595.0, 842.0, 1.0, 16),
            // moving left/up gives negative deltas
            StrokePoint(0.01, 0.02, 0.25, 40),
          ]),
        ],
        7: [
          _stroke(2, const [StrokePoint(5, 5, 0.5, 0)],
              tool: InkTool.highlighter, color: 0xFFFFEB3B, width: 14),
        ],
      };
      final bytes = StrokeCodec.encodeDocument(original, 3);
      final decoded = StrokeCodec.decodeDocument(bytes);

      expect(decoded.nextStrokeId, 3);
      expect(decoded.pages.keys.toSet(), {1, 7});

      final a = original[1]!.single, b = decoded.pages[1]!.single;
      expect(b.id, 1);
      expect(b.tool, InkTool.pen);
      expect(b.color, 0xFFD32F2F);
      expect(b.width, closeTo(1.6, 0.0051));
      expect(b.points.length, a.points.length);
      for (var i = 0; i < a.points.length; i++) {
        expect(b.points[i].x, closeTo(a.points[i].x, 0.005));
        expect(b.points[i].y, closeTo(a.points[i].y, 0.005));
        expect(b.points[i].pressure, closeTo(a.points[i].pressure, 1 / 255));
        expect(b.points[i].t, a.points[i].t);
      }

      final h = decoded.pages[7]!.single;
      expect(h.tool, InkTool.highlighter);
      expect(h.color, 0xFFFFEB3B);
      expect(h.width, closeTo(14, 0.0051));
    });

    test('is compact: about 5 bytes per point', () {
      final pts = [
        for (var i = 0; i < 1000; i++)
          StrokePoint(100 + i * 0.37, 200 + (i % 17) * 0.21, 0.5, i * 8),
      ];
      final bytes = StrokeCodec.encodeDocument({1: [_stroke(1, pts)]}, 2);
      expect(bytes.length / 1000, lessThan(7));
    });

    test('rejects data that is not a NOTS file', () {
      expect(() => StrokeCodec.decodeDocument(Uint8List.fromList([1, 2, 3, 4, 5])),
          throwsFormatException);
    });

    test('rejects truncated data', () {
      final bytes = StrokeCodec.encodeDocument({
        1: [_stroke(1, const [StrokePoint(1, 1, 0.5, 0), StrokePoint(2, 2, 0.5, 5)])]
      }, 2);
      expect(
          () => StrokeCodec.decodeDocument(
              Uint8List.sublistView(bytes, 0, bytes.length - 3)),
          throwsFormatException);
    });
  });

  group('Stroke.distanceTo', () {
    final s = _stroke(1, const [
      StrokePoint(0, 0, 0.5, 0),
      StrokePoint(10, 0, 0.5, 1),
    ], width: 2);

    test('is measured to the segment, minus half the width', () {
      expect(s.distanceTo(5, 3), closeTo(2, 1e-9)); // 3 - 1
      expect(s.distanceTo(5, 0), closeTo(-1, 1e-9)); // on the line
      expect(s.distanceTo(13, 4), closeTo(4, 1e-9)); // 5 - 1, beyond the end
    });
  });

  group('InkDocument', () {
    InkDocument docWithTwoStrokes() {
      final d = InkDocument();
      d.add(1, _stroke(d.takeStrokeId(),
          const [StrokePoint(0, 0, 0.5, 0), StrokePoint(10, 0, 0.5, 1)]));
      d.add(1, _stroke(d.takeStrokeId(),
          const [StrokePoint(0, 20, 0.5, 0), StrokePoint(10, 20, 0.5, 1)]));
      return d;
    }

    test('undo and redo of an added stroke', () {
      final d = docWithTwoStrokes();
      expect(d.strokesOf(1).length, 2);
      expect(d.undo(), isTrue);
      expect(d.strokesOf(1).length, 1);
      expect(d.redo(), isTrue);
      expect(d.strokesOf(1).length, 2);
      expect(d.redo(), isFalse);
    });

    test('a new stroke clears the redo stack', () {
      final d = docWithTwoStrokes();
      d.undo();
      expect(d.canRedo, isTrue);
      d.add(1, _stroke(d.takeStrokeId(), const [StrokePoint(1, 1, 0.5, 0)]));
      expect(d.canRedo, isFalse);
    });

    test('one erase drag is one undo step and restores every stroke', () {
      final d = docWithTwoStrokes();
      final ids = d.strokesOf(1).map((s) => s.id).toSet();

      d.beginErase(1);
      expect(d.eraseAt(5, 0, 2), isTrue); // first stroke
      expect(d.eraseAt(5, 20, 2), isTrue); // second stroke
      d.endErase();
      expect(d.strokesOf(1), isEmpty);

      expect(d.undo(), isTrue);
      expect(d.strokesOf(1).map((s) => s.id).toSet(), ids);

      expect(d.redo(), isTrue);
      expect(d.strokesOf(1), isEmpty);
    });

    test('erasing empty space changes nothing and adds no undo step', () {
      final d = docWithTwoStrokes();
      d.undo();
      d.undo();
      d.redo();
      d.redo();
      d.beginErase(1);
      expect(d.eraseAt(500, 500, 2), isFalse);
      d.endErase();
      expect(d.strokesOf(1).length, 2);
      // The only undoable steps are the two adds.
      d.undo();
      d.undo();
      expect(d.canUndo, isFalse);
    });

    test('revision of a page changes only for that page', () {
      final d = InkDocument();
      final r1 = d.revisionOf(1), r2 = d.revisionOf(2);
      final before1 = r1.value, before2 = r2.value;
      d.add(1, _stroke(d.takeStrokeId(), const [StrokePoint(1, 1, 0.5, 0)]));
      expect(r1.value, isNot(before1));
      expect(r2.value, before2);
    });
  });
}
