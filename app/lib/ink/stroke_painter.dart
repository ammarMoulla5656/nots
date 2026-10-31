import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'stroke.dart';

/// Paints strokes of one page. [scale] converts PDF points to screen pixels,
/// so the same stroke data renders sharp at any zoom.
void paintStroke(Canvas canvas, Stroke s, double scale) {
  final pts = s.points;
  if (pts.isEmpty) return;
  if (s.tool == InkTool.calligraphy) {
    _paintCalligraphy(canvas, s, scale);
    return;
  }
  final isHighlighter = s.tool == InkTool.highlighter;
  final base = s.width * scale;
  // Pencil: slightly translucent and thinner so overlapping strokes darken.
  final alpha = isHighlighter ? 0.35 : (s.tool == InkTool.pencil ? 0.8 : 1.0);
  final color = Color(s.color).withValues(alpha: alpha);

  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeCap = isHighlighter ? StrokeCap.butt : StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  if (pts.length == 1) {
    canvas.drawCircle(
      Offset(pts[0].x * scale, pts[0].y * scale),
      base / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }

  final pressures = pts.map((p) => p.pressure);
  final varies = !isHighlighter &&
      (pressures.reduce((a, b) => a > b ? a : b) -
              pressures.reduce((a, b) => a < b ? a : b)) >
          0.05;

  if (!varies) {
    paint.strokeWidth = base;
    canvas.drawPath(_smoothPath(pts, scale), paint);
    return;
  }

  // Pressure-sensitive pen: width follows pressure segment by segment.
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final pr = (a.pressure + b.pressure) / 2;
    paint.strokeWidth = base * (0.5 + pr);
    canvas.drawLine(
      Offset(a.x * scale, a.y * scale),
      Offset(b.x * scale, b.y * scale),
      paint,
    );
  }
}

/// Flat-nib pen: the nib is a tilted line segment dragged along the path, so
/// strokes are thick across the nib and thin along it (like a qalam).
void _paintCalligraphy(Canvas canvas, Stroke s, double scale) {
  final pts = s.points;
  const angle = -math.pi / 4; // nib tilted 45 degrees, rising to the right
  final half = Offset(math.cos(angle), math.sin(angle)) * (s.width * scale * 1.1);
  final fill = Paint()
    ..color = Color(s.color)
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;
  Offset at(StrokePoint p) => Offset(p.x * scale, p.y * scale);
  if (pts.length == 1) {
    final c = at(pts[0]);
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - half.dx, c.dy - half.dy)
        ..lineTo(c.dx + half.dx, c.dy + half.dy)
        ..lineTo(c.dx + half.dx + 0.5, c.dy + half.dy)
        ..close(),
      fill,
    );
    return;
  }
  // One quad per segment, drawn separately: quads of opposite winding in a
  // single path would cancel where they overlap and leave holes.
  for (var i = 1; i < pts.length; i++) {
    final a = at(pts[i - 1]), b = at(pts[i]);
    canvas.drawPath(
      Path()
        ..moveTo(a.dx - half.dx, a.dy - half.dy)
        ..lineTo(a.dx + half.dx, a.dy + half.dy)
        ..lineTo(b.dx + half.dx, b.dy + half.dy)
        ..lineTo(b.dx - half.dx, b.dy - half.dy)
        ..close(),
      fill,
    );
  }
}

/// Quadratic curve through the midpoints of consecutive samples: smooth
/// without needing extra points.
ui.Path _smoothPath(List<StrokePoint> pts, double scale) {
  final path = ui.Path()..moveTo(pts[0].x * scale, pts[0].y * scale);
  for (var i = 1; i < pts.length - 1; i++) {
    final mx = (pts[i].x + pts[i + 1].x) / 2 * scale;
    final my = (pts[i].y + pts[i + 1].y) / 2 * scale;
    path.quadraticBezierTo(pts[i].x * scale, pts[i].y * scale, mx, my);
  }
  final last = pts.last;
  path.lineTo(last.x * scale, last.y * scale);
  return path;
}

class StrokesPainter extends CustomPainter {
  StrokesPainter({
    required this.strokes,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<Stroke> Function() strokes;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes()) {
      paintStroke(canvas, s, scale);
    }
  }

  @override
  bool shouldRepaint(StrokesPainter old) => old.scale != scale;
}

/// Selected strokes (shifted by the drag offset), their frame, and the lasso
/// loop while it is being drawn.
class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.selected,
    required this.offset,
    required this.lasso,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<Stroke> Function() selected;
  final Offset Function() offset;
  final List<Offset> Function() lasso;
  final double scale;

  static const _blue = Color(0xFF1E88E5);

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selected();
    if (sel.isNotEmpty) {
      final off = offset();
      canvas.save();
      canvas.translate(off.dx * scale, off.dy * scale);
      Rect? box;
      for (final s in sel) {
        paintStroke(canvas, s, scale);
        box = box == null ? s.bounds : box.expandToInclude(s.bounds);
      }
      final r = Rect.fromLTRB(box!.left * scale, box.top * scale,
              box.right * scale, box.bottom * scale)
          .inflate(4);
      canvas.drawRect(r, Paint()..color = _blue.withValues(alpha: 0.08));
      canvas.drawRect(
        r,
        Paint()
          ..color = _blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.restore();
    }
    final loop = lasso();
    if (loop.length > 1) {
      final path = Path()..moveTo(loop[0].dx * scale, loop[0].dy * scale);
      for (final p in loop.skip(1)) {
        path.lineTo(p.dx * scale, p.dy * scale);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(SelectionPainter old) => old.scale != scale;
}

/// The stroke being drawn right now, repainted on every pointer move without
/// touching the committed strokes.
class LiveStrokePainter extends CustomPainter {
  LiveStrokePainter({
    required this.current,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Stroke? Function() current;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = current();
    if (s != null) paintStroke(canvas, s, scale);
  }

  @override
  bool shouldRepaint(LiveStrokePainter old) => old.scale != scale;
}
