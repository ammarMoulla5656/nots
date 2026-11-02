import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ruler.dart';
import 'package:nots/ink/words.dart';

void main() {
  const r = Ruler(page: 1, center: Offset(200, 300), length: 400, thickness: 50);

  test('contains: body only, with optional slack', () {
    expect(r.contains(const Offset(200, 300)), isTrue);
    expect(r.contains(const Offset(390, 320)), isTrue);
    expect(r.contains(const Offset(420, 300)), isFalse);
    expect(r.contains(const Offset(420, 300), slack: 30), isTrue);
    expect(r.contains(const Offset(200, 340)), isFalse);
  });

  test('edge detection and snapping on a horizontal ruler', () {
    // bottom edge is y = 325, top edge y = 275
    expect(r.edgeSideNear(const Offset(150, 330), 10), 1);
    expect(r.edgeSideNear(const Offset(150, 270), 10), -1);
    expect(r.edgeSideNear(const Offset(150, 300), 10), isNull); // middle
    expect(r.edgeSideNear(const Offset(600, 330), 10), isNull); // past the end
    final s = r.snapToEdge(const Offset(150, 331), 1);
    expect(s.dy, closeTo(325, 1e-9));
    expect(s.dx, closeTo(150, 1e-9));
    // beyond the ends it stops at the end of the ruler
    expect(r.snapToEdge(const Offset(900, 331), 1).dx, closeTo(400, 1e-9));
  });

  test('a rotated ruler snaps along its own direction', () {
    final rot = r.copyWith(angle: math.pi / 2); // vertical
    // now the long edges are x = 200 ± 25
    final side = rot.edgeSideNear(const Offset(172, 250), 10)!;
    final s = rot.snapToEdge(const Offset(172, 250), side);
    expect((s.dx - 200).abs(), closeTo(25, 1e-9));
    expect(s.dy, closeTo(250, 1e-9));
  });

  test('two fingers rotate and move it', () {
    final moved = r.twoFingers(const Offset(100, 100), const Offset(200, 100),
        const Offset(110, 120), const Offset(110, 220));
    expect(moved.angle, closeTo(math.pi / 2, 1e-9));
    expect(moved.center.dx, closeTo(200 + (110 - 150), 1e-9));
    expect(moved.center.dy, closeTo(300 + (170 - 100), 1e-9));
  });

  group('wordsAlongPath', () {
    final words = [
      WordBox(0, 3, 'a', const Rect.fromLTWH(10, 10, 40, 12)),
      WordBox(4, 7, 'b', const Rect.fromLTWH(60, 10, 40, 12)),
      WordBox(8, 11, 'c', const Rect.fromLTWH(10, 40, 40, 12)),
    ];

    test('a stroke along a line catches the words on it, in order', () {
      expect(wordsAlongPath(words, const [Offset(5, 16), Offset(120, 16)]), [0, 1]);
    });

    test('a stroke over empty space catches nothing', () {
      expect(wordsAlongPath(words, const [Offset(5, 100), Offset(120, 100)]), isEmpty);
    });

    test('a fast stroke with few points still catches words between them', () {
      expect(wordsAlongPath(words, const [Offset(0, 16), Offset(200, 16)]), [0, 1]);
    });
  });
}
