import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/words.dart';
import 'package:nots/reader/touch_navigator.dart';
import 'package:nots/ui/color_wheel.dart';

Offset _apply(Matrix4 m, Offset p) => MatrixUtils.transformPoint(m, p);

void main() {
  group('pinchMatrix', () {
    test('the page point under the fingers stays under the fingers', () {
      final start = Matrix4.identity()
        ..translateByDouble(30, -40, 0, 1)
        ..scaleByDouble(1.5, 1.5, 1, 1);
      const f0 = Offset(200, 300), f = Offset(260, 280);
      final m = pinchMatrix(start, f0, 100, f, 250);
      // the document point that was under f0 ...
      final inv = Matrix4.inverted(start);
      final doc = _apply(inv, f0);
      // ... is now under f, and the zoom grew 2.5x
      final now = _apply(m, doc);
      expect(now.dx, closeTo(f.dx, 1e-6));
      expect(now.dy, closeTo(f.dy, 1e-6));
      expect(m.getMaxScaleOnAxis(), closeTo(1.5 * 2.5, 1e-9));
    });

    test('fingers moving together without spreading only scroll', () {
      final m = pinchMatrix(Matrix4.identity(), const Offset(100, 100), 80,
          const Offset(100, 40), 80);
      expect(m.getMaxScaleOnAxis(), closeTo(1, 1e-9));
      expect(_apply(m, Offset.zero), const Offset(0, -60));
    });

    test('panMatrix shifts the view', () {
      final m = panMatrix(Matrix4.identity()..scaleByDouble(2, 2, 1, 1),
          const Offset(5, -7));
      expect(_apply(m, const Offset(1, 1)), const Offset(7, -5));
    });
  });

  group('wheelPick', () {
    const c = Offset(100, 100);
    test('direction is the hue, distance is the saturation', () {
      final right = wheelPick(const Offset(200, 100), c, 100);
      expect(right.hue, closeTo(0, 1e-9));
      expect(right.saturation, closeTo(1, 1e-9));
      final down = wheelPick(const Offset(100, 150), c, 100);
      expect(down.hue, closeTo(90, 1e-9)); // clockwise on screen
      expect(down.saturation, closeTo(0.5, 1e-9));
      final left = wheelPick(const Offset(0, 100), c, 100);
      expect(left.hue, closeTo(180, 1e-9));
      final up = wheelPick(const Offset(100, 0), c, 100);
      expect(up.hue, closeTo(270, 1e-9));
    });

    test('outside the rim stays fully saturated, centre is white', () {
      expect(wheelPick(const Offset(400, 100), c, 100).saturation, 1);
      expect(wheelPick(c, c, 100).saturation, 0);
    });
  });

  group('words', () {
    Rect ch(double x, double y) => Rect.fromLTWH(x, y, 6, 12);

    test('splits on spaces and on line changes', () {
      // "ab cd" on one line, then "ef" on the next line with no space
      const text = 'ab cdef';
      final rects = <Rect?>[
        ch(100, 10), ch(94, 10), null, ch(80, 10), ch(74, 10),
        ch(100, 30), ch(94, 30),
      ];
      final w = splitWords(text, rects);
      expect(w.map((e) => e.text), ['ab', 'cd', 'ef']);
      expect(w[0].rect, Rect.fromLTRB(94, 10, 106, 22));
      expect(w[2].rect.top, 30);
    });

    test('wordAt finds the word under a finger, with tolerance', () {
      final w = splitWords('ab cd', [ch(100, 10), ch(94, 10), null, ch(80, 10), ch(74, 10)]);
      expect(wordAt(w, const Offset(97, 15)), 0);
      expect(wordAt(w, const Offset(77, 15)), 1);
      expect(wordAt(w, const Offset(77, 25)), isNull);
      expect(wordAt(w, const Offset(77, 23), tolerance: 2), 1);
    });

    test('lineRects merges words of the same line', () {
      final w = [
        WordBox(0, 1, 'a', ch(100, 10)),
        WordBox(2, 3, 'b', ch(80, 11)),
        WordBox(4, 5, 'c', ch(100, 30)),
      ];
      final lines = lineRects(w);
      expect(lines.length, 2);
      expect(lines[0].left, 80);
      expect(lines[0].right, 106);
      expect(math.max(lines[0].bottom, 22), lines[0].bottom);
    });
  });
}
