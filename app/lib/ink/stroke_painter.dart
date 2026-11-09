import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'selection.dart';
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
  final alpha = isHighlighter ? 0.55 : (s.tool == InkTool.pencil ? 0.8 : 1.0);
  final color = Color(s.color).withValues(alpha: alpha);

  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeCap = isHighlighter ? StrokeCap.butt : StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  // The highlighter multiplies with the page: the letters under it keep
  // their colour instead of being washed out.
  if (isHighlighter) paint.blendMode = BlendMode.multiply;

  if (pts.length == 1) {
    canvas.drawCircle(
      Offset(pts[0].x * scale, pts[0].y * scale),
      base / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }

  final pressures = pts.map((p) => p.pressure);
  final varies =
      !isHighlighter &&
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
  final half =
      Offset(math.cos(angle), math.sin(angle)) * (s.width * scale * 1.1);
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

/// The strokes of one page kept as a ready picture, in PDF points.
///
/// Drawing every stroke again on each change made a page slow once it held
/// hundreds of strokes. Now a new stroke is recorded on top of the picture
/// already made (the old ones are not drawn again), zooming only scales the
/// picture, and only removing or changing strokes records them all anew.
class StrokeLayer {
  ui.Picture? _picture;

  /// Pictures the current one draws on top of; kept alive until it is
  /// recorded flat again.
  final _under = <ui.Picture>[];

  /// The strokes in the picture. Strokes never change in place (a changed
  /// stroke is a new object), so comparing references tells what changed.
  List<Stroke> _drawn = const [];
  int _hiddenKey = 0;
  int _appends = 0;

  /// How many times all strokes were recorded (for tests).
  int fullRecords = 0;

  /// Recorded flat again after this many strokes added on top.
  static const flattenEvery = 64;

  /// Whether the first [n] of [strokes] are the ones in the picture.
  bool _samePrefix(List<Stroke> strokes, int n) {
    for (var i = 0; i < n; i++) {
      if (!identical(strokes[i], _drawn[i])) return false;
    }
    return true;
  }

  /// The picture of [strokes] without the [hidden] ones (being moved by the
  /// selection).
  ui.Picture pictureFor(List<Stroke> strokes, Set<int> hidden) {
    final hiddenKey = hidden.isEmpty ? 0 : Object.hashAllUnordered(hidden);
    final pic = _picture;
    final n = _drawn.length;
    final sameHidden = hiddenKey == _hiddenKey;
    if (pic != null &&
        sameHidden &&
        strokes.length == n &&
        _samePrefix(strokes, n)) {
      return pic;
    }
    final appended =
        pic != null &&
        sameHidden &&
        n > 0 &&
        strokes.length > n &&
        _appends < flattenEvery &&
        _samePrefix(strokes, n);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (appended) {
      canvas.drawPicture(pic);
      for (var i = n; i < strokes.length; i++) {
        if (!hidden.contains(strokes[i].id)) paintStroke(canvas, strokes[i], 1);
      }
      _under.add(pic);
      _appends++;
    } else {
      for (final s in strokes) {
        if (!hidden.contains(s.id)) paintStroke(canvas, s, 1);
      }
      _release();
      pic?.dispose();
      _appends = 0;
      fullRecords++;
    }
    _picture = recorder.endRecording();
    _drawn = List.of(strokes);
    _hiddenKey = hiddenKey;
    return _picture!;
  }

  void _release() {
    for (final p in _under) {
      p.dispose();
    }
    _under.clear();
  }

  void dispose() {
    _release();
    _picture?.dispose();
    _picture = null;
  }
}

class StrokesPainter extends CustomPainter {
  StrokesPainter({
    required this.layer,
    required this.strokes,
    required this.hidden,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final StrokeLayer layer;
  final List<Stroke> Function() strokes;

  /// Strokes not drawn here (the selection draws them while they move).
  final Set<int> Function() hidden;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final picture = layer.pictureFor(strokes(), hidden());
    canvas
      ..save()
      ..scale(scale)
      ..drawPicture(picture)
      ..restore();
  }

  @override
  bool shouldRepaint(StrokesPainter old) => old.scale != scale;
}

/// How the selected strokes are shown while being dragged or resized:
/// scaled by [factor] around [anchor], then shifted by [offset] (PDF points).
class SelectionTransform {
  const SelectionTransform({
    this.offset = Offset.zero,
    this.factor = 1,
    this.anchor = Offset.zero,
  });

  final Offset offset;
  final double factor;
  final Offset anchor;
}

/// Selected strokes (shown with a live transform), the selection frame with
/// its corner handles and delete/edit buttons, and the lasso loop while it is
/// being drawn.
class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.selected,
    required this.transform,
    required this.frame,
    required this.unit,
    required this.canEdit,
    required this.canResize,
    required this.lasso,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<Stroke> Function() selected;
  final SelectionTransform Function() transform;

  /// Bounds of what is selected right now (already moved/resized), or null.
  final Rect? Function() frame;

  /// PDF points per screen pixel (keeps buttons the same size at any zoom).
  final double Function() unit;
  final bool Function() canEdit;
  final bool Function() canResize;
  final List<Offset> Function() lasso;
  final double scale;

  static const _blue = Color(0xFF1E88E5);

  void _icon(
    Canvas canvas,
    IconData icon,
    Offset center,
    double size,
    Color c,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: c,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selected();
    if (sel.isNotEmpty) {
      final t = transform();
      canvas.save();
      canvas.translate(t.offset.dx * scale, t.offset.dy * scale);
      canvas.translate(t.anchor.dx * scale, t.anchor.dy * scale);
      canvas.scale(t.factor);
      canvas.translate(-t.anchor.dx * scale, -t.anchor.dy * scale);
      for (final s in sel) {
        paintStroke(canvas, s, scale);
      }
      canvas.restore();
    }

    final bounds = frame();
    if (bounds != null) {
      final u = unit();
      final px = u * scale; // layout pixels per screen pixel
      final geo = SelectionGeometry(
        bounds,
        u,
        canEdit: canEdit(),
        canResize: canResize(),
      );
      Rect toPx(Rect r) => Rect.fromLTRB(
        r.left * scale,
        r.top * scale,
        r.right * scale,
        r.bottom * scale,
      );
      final r = toPx(geo.frame);
      // Thin frame and small controls: they must not hide the writing.
      canvas.drawRect(r, Paint()..color = _blue.withValues(alpha: 0.05));
      canvas.drawRect(
        r,
        Paint()
          ..color = _blue.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 * px,
      );
      if (canResize()) {
        for (final c in geo.corners) {
          final h = Rect.fromCenter(
            center: c * scale,
            width: 7 * px,
            height: 7 * px,
          );
          canvas.drawRect(h, Paint()..color = Colors.white);
          canvas.drawRect(
            h,
            Paint()
              ..color = _blue
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2 * px,
          );
        }
      }
      const rr = SelectionGeometry.buttonRadiusPx;
      final close = geo.closeCenter * scale;
      canvas.drawCircle(
        close,
        rr * px,
        Paint()..color = const Color(0xFFD32F2F),
      );
      _icon(canvas, Icons.close, close, 13 * px, Colors.white);
      if (canEdit()) {
        final edit = geo.editCenter * scale;
        canvas.drawCircle(edit, rr * px, Paint()..color = _blue);
        _icon(canvas, Icons.edit, edit, 12 * px, Colors.white);
      }
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
