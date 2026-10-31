import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/selection.dart';
import 'package:nots/ink/stroke.dart';

Stroke _line(int id, double x0, double y0, double x1, double y1,
        {int color = 0xFF000000}) =>
    Stroke(
      id: id,
      tool: InkTool.pen,
      color: color,
      width: 2,
      points: [StrokePoint(x0, y0, 0.5, 0), StrokePoint(x1, y1, 0.5, 5)],
    );

const _square = [Offset(0, 0), Offset(100, 0), Offset(100, 100), Offset(0, 100)];

void main() {
  test('pointInPolygon', () {
    expect(pointInPolygon(50, 50, _square), isTrue);
    expect(pointInPolygon(150, 50, _square), isFalse);
    expect(pointInPolygon(-1, 50, _square), isFalse);
    // concave "L" shape: the notch is outside
    const l = [Offset(0, 0), Offset(100, 0), Offset(100, 40), Offset(40, 40), Offset(40, 100), Offset(0, 100)];
    expect(pointInPolygon(20, 80, l), isTrue);
    expect(pointInPolygon(80, 80, l), isFalse);
  });

  test('lasso selects strokes with at least half their points inside', () {
    final inside = _line(1, 10, 10, 90, 90);
    final outside = _line(2, 200, 200, 300, 300);
    final half = _line(3, 50, 50, 150, 50); // 1 of 2 points inside
    final ids = strokesInLasso([inside, outside, half], _square);
    expect(ids, {1, 3});
    expect(strokesInLasso([inside], const [Offset(0, 0), Offset(1, 1)]), isEmpty);
  });

  group('SelectionController', () {
    late InkDocument doc;
    late SelectionController sel;
    setUp(() {
      doc = InkDocument();
      doc.add(1, _line(doc.takeStrokeId(), 10, 10, 20, 10));
      doc.add(1, _line(doc.takeStrokeId(), 10, 50, 20, 50));
      sel = SelectionController(doc);
    });
    tearDown(() => sel.dispose());

    test('move is one undo step and keeps z-order and ids', () {
      sel.select(1, {1});
      sel.moveBy(5, 7);
      final moved = doc.strokesOf(1).first;
      expect(moved.id, 1);
      expect(moved.points.first.x, closeTo(15, 1e-9));
      expect(moved.points.first.y, closeTo(17, 1e-9));
      expect(doc.strokesOf(1).map((s) => s.id), [1, 2]);

      doc.undo();
      expect(doc.strokesOf(1).first.points.first.x, closeTo(10, 1e-9));
      doc.redo();
      expect(doc.strokesOf(1).first.points.first.x, closeTo(15, 1e-9));
    });

    test('delete then undo restores the stroke at its place', () {
      sel.select(1, {1});
      sel.deleteSelected();
      expect(doc.strokesOf(1).map((s) => s.id), [2]);
      expect(sel.active, isFalse);
      doc.undo();
      expect(doc.strokesOf(1).map((s) => s.id), [1, 2]);
    });

    test('duplicate adds copies with new ids and selects them', () {
      sel.select(1, {1, 2});
      sel.duplicateSelected(offset: 10);
      expect(doc.strokesOf(1).length, 4);
      expect(sel.ids.length, 2);
      expect(sel.ids.intersection({1, 2}), isEmpty);
      expect(sel.strokes.first.points.first.x, closeTo(20, 1e-9));
      doc.undo();
      expect(doc.strokesOf(1).length, 2);
      expect(sel.active, isFalse); // copies vanished, selection pruned
    });

    test('recolor changes only the colour', () {
      sel.select(1, {2});
      sel.recolor(0xFFD32F2F);
      expect(doc.strokesOf(1)[1].color, 0xFFD32F2F);
      expect(doc.strokesOf(1)[0].color, 0xFF000000);
    });

    test('bounds covers every selected stroke', () {
      sel.select(1, {1, 2});
      final b = sel.bounds!;
      expect(b.left, lessThanOrEqualTo(10));
      expect(b.right, greaterThanOrEqualTo(20));
      expect(b.top, lessThanOrEqualTo(10));
      expect(b.bottom, greaterThanOrEqualTo(50));
    });
  });
}
