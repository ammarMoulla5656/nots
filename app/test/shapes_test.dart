import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/shapes.dart';

final _rnd = math.Random(7);

Offset _jitter(Offset p, double amount) => Offset(
  p.dx + (_rnd.nextDouble() - 0.5) * amount,
  p.dy + (_rnd.nextDouble() - 0.5) * amount,
);

/// Samples a polyline densely, like pointer events would, with hand shake.
List<Offset> _hand(List<Offset> poly, {double step = 3, double shake = 1.5}) {
  final out = <Offset>[];
  for (var i = 1; i < poly.length; i++) {
    final a = poly[i - 1], b = poly[i];
    final n = math.max(1, ((b - a).distance / step).round());
    for (var k = 0; k < n; k++) {
      out.add(_jitter(Offset.lerp(a, b, k / n)!, shake));
    }
  }
  out.add(_jitter(poly.last, shake));
  return out;
}

List<Offset> _circle(Offset c, double rx, double ry, {double overlap = 0.1}) =>
    [
      for (var i = 0; i <= 80; i++)
        Offset(
          c.dx + rx * math.cos(2 * math.pi * (1 + overlap) * i / 80),
          c.dy + ry * math.sin(2 * math.pi * (1 + overlap) * i / 80),
        ),
    ];

void main() {
  test('a wobbly straight line snaps to its two end points', () {
    final raw = _hand(const [Offset(10, 10), Offset(210, 40)]);
    final s = snapShape(raw)!;
    expect(s.length, 2);
    expect((s.first - raw.first).distance, lessThan(1e-9));
    expect((s.last - raw.last).distance, lessThan(1e-9));
  });

  test('a circle and an ellipse snap to an ellipse', () {
    for (final (rx, ry) in [(60.0, 60.0), (90.0, 40.0), (30.0, 70.0)]) {
      final s = snapShape(
        _hand(_circle(const Offset(200, 200), rx, ry), step: 4),
      );
      expect(s, isNotNull, reason: 'ellipse $rx x $ry');
      expect(s!.length, greaterThan(20));
    }
  });

  test('a rectangle snaps to its four corners', () {
    final raw = _hand(const [
      Offset(50, 50),
      Offset(250, 50),
      Offset(250, 150),
      Offset(50, 150),
      Offset(52, 52),
    ]);
    final s = snapShape(raw)!;
    expect(s.length, 5);
    expect(s[0].dx, closeTo(50, 4));
    expect(s[2].dx, closeTo(250, 4));
    expect(s[2].dy, closeTo(150, 4));
  });

  test('a square snaps to a rectangle, not an ellipse', () {
    final s = snapShape(
      _hand(const [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
        Offset(0, 100),
        Offset(1, 1),
      ]),
    )!;
    expect(s.length, 5);
  });

  test('curves, scribbles and tiny strokes are left alone', () {
    // open arc (a "C")
    final arc = _hand([
      for (var i = 0; i <= 30; i++)
        Offset(
          100 + 60 * math.cos(0.6 + 4.5 * i / 30),
          100 + 60 * math.sin(0.6 + 4.5 * i / 30),
        ),
    ]);
    expect(snapShape(arc), isNull);

    // gentle S curve
    final s = _hand([
      for (var i = 0; i <= 40; i++)
        Offset(i * 5.0, 30 * math.sin(i / 40 * 2 * math.pi)),
    ]);
    expect(snapShape(s), isNull);

    // zig-zag
    final zig = _hand(const [
      Offset(0, 0),
      Offset(40, 30),
      Offset(80, 0),
      Offset(120, 30),
      Offset(160, 0),
    ]);
    expect(snapShape(zig), isNull);

    // tiny dot-like stroke
    expect(
      snapShape(_hand(const [Offset(0, 0), Offset(6, 2)], step: 1)),
      isNull,
    );
  });

  test('shapePoints builds closed outlines for dragging', () {
    final rect = shapePoints(
      ShapeKind.rectangle,
      const Offset(0, 0),
      const Offset(10, 20),
    );
    expect(rect.first, rect.last);
    expect(rect.length, 5);
    final arrow = shapePoints(
      ShapeKind.arrow,
      const Offset(0, 0),
      const Offset(100, 0),
    );
    expect(arrow.length, 5);
    expect(arrow[1], const Offset(100, 0));
    final ell = shapePoints(
      ShapeKind.ellipse,
      const Offset(0, 0),
      const Offset(20, 10),
    );
    expect((ell.first - ell.last).distance, lessThan(1e-9));
    final tri = shapePoints(
      ShapeKind.triangle,
      const Offset(0, 0),
      const Offset(10, 10),
    );
    expect(tri.first, tri.last);
  });
}
