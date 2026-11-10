import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/ink/stroke_painter.dart';

Stroke _stroke(int id) => Stroke(
  id: id,
  tool: InkTool.pen,
  color: 0xFF0D47A1,
  width: 1.6,
  points: [
    for (var i = 0; i < 20; i++)
      StrokePoint(10.0 + i * 5, 20.0 + id % 700, 0.5, i * 10),
  ],
);

void main() {
  test('a new stroke is added on top: the old ones are not drawn again', () {
    final layer = StrokeLayer();
    final strokes = [for (var i = 1; i <= 1000; i++) _stroke(i)];
    layer.pictureFor(strokes, const {});
    expect(layer.fullRecords, 1);

    // The same strokes: the same picture, nothing recorded.
    final same = layer.pictureFor(strokes, const {});
    expect(
      identical(same, layer.pictureFor(List.of(strokes), const {})),
      isTrue,
    );
    expect(layer.fullRecords, 1);

    // Writing: one stroke after another, never all again.
    for (var i = 1001; i <= 1050; i++) {
      strokes.add(_stroke(i));
      layer.pictureFor(strokes, const {});
    }
    expect(layer.fullRecords, 1);
    layer.dispose();
  });

  test('erasing, changing or moving strokes draws them all again', () {
    final layer = StrokeLayer();
    final strokes = [for (var i = 1; i <= 100; i++) _stroke(i)];
    layer.pictureFor(strokes, const {});

    strokes.removeAt(10); // erased
    layer.pictureFor(strokes, const {});
    expect(layer.fullRecords, 2);

    strokes[5] = _stroke(5); // changed: a new object in the same place
    layer.pictureFor(strokes, const {});
    expect(layer.fullRecords, 3);

    layer.pictureFor(strokes, {7, 8}); // selected: drawn by the selection
    expect(layer.fullRecords, 4);
    layer.pictureFor(strokes, {7, 8});
    expect(layer.fullRecords, 4);
    layer.dispose();
  });

  test('after many strokes on top the picture is recorded flat again', () {
    final layer = StrokeLayer();
    final strokes = [_stroke(1)];
    layer.pictureFor(strokes, const {});
    for (var i = 2; i <= StrokeLayer.flattenEvery + 2; i++) {
      strokes.add(_stroke(i));
      layer.pictureFor(strokes, const {});
    }
    expect(layer.fullRecords, 2);
    layer.dispose();
  });
}
