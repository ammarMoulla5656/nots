import 'dart:math' as math;
import 'dart:ui';

/// A straight-edge ruler placed on a page. Lines drawn along its edge become
/// straight. Positions are in PDF points of the page it stands on.
class Ruler {
  const Ruler({
    required this.page,
    required this.center,
    this.angle = 0,
    this.length = 400,
    this.thickness = 54,
  });

  final int page;
  final Offset center;

  /// Direction of the long edge, in radians (0 = left to right).
  final double angle;
  final double length;
  final double thickness;

  /// One centimetre in PDF points.
  static const cm = 72 / 2.54;

  Ruler copyWith({int? page, Offset? center, double? angle}) => Ruler(
        page: page ?? this.page,
        center: center ?? this.center,
        angle: angle ?? this.angle,
        length: length,
        thickness: thickness,
      );

  Offset get direction => Offset(math.cos(angle), math.sin(angle));
  Offset get normal => Offset(-math.sin(angle), math.cos(angle));

  /// [p] in the ruler's own frame: x along the long edge, y across it.
  Offset toLocal(Offset p) {
    final d = p - center;
    return Offset(
      d.dx * direction.dx + d.dy * direction.dy,
      d.dx * normal.dx + d.dy * normal.dy,
    );
  }

  Offset fromLocal(Offset l) =>
      center + direction * l.dx + normal * l.dy;

  /// Whether [p] is on the ruler's body (widened by [slack]).
  bool contains(Offset p, {double slack = 0}) {
    final l = toLocal(p);
    return l.dx.abs() <= length / 2 + slack && l.dy.abs() <= thickness / 2 + slack;
  }

  /// The edge a stroke starting at [p] would follow: [p] must be within
  /// [tolerance] of a long edge (and over its length). Returns the side
  /// (-1 or +1), or null.
  int? edgeSideNear(Offset p, double tolerance) {
    final l = toLocal(p);
    if (l.dx.abs() > length / 2 + tolerance) return null;
    for (final side in const [-1, 1]) {
      if ((l.dy - side * thickness / 2).abs() <= tolerance) return side;
    }
    return null;
  }

  /// [p] projected onto the long edge on [side], kept within the ruler's
  /// length.
  Offset snapToEdge(Offset p, int side) {
    final l = toLocal(p);
    final x = l.dx.clamp(-length / 2, length / 2);
    return fromLocal(Offset(x, side * thickness / 2));
  }

  /// New ruler after two fingers on it moved from [a0],[b0] to [a1],[b1]:
  /// follows the midpoint and the direction between the fingers.
  Ruler twoFingers(Offset a0, Offset b0, Offset a1, Offset b1) {
    final mid0 = (a0 + b0) / 2, mid1 = (a1 + b1) / 2;
    final ang0 = math.atan2((b0 - a0).dy, (b0 - a0).dx);
    final ang1 = math.atan2((b1 - a1).dy, (b1 - a1).dx);
    var d = ang1 - ang0;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    return copyWith(center: center + (mid1 - mid0), angle: angle + d);
  }
}
