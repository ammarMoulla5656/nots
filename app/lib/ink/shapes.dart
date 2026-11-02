import 'dart:math' as math;
import 'dart:ui';

enum ShapeKind { line, arrow, rectangle, ellipse, triangle }

/// Outline of [kind] spanning the drag from [a] to [b], as a polyline.
List<Offset> shapePoints(ShapeKind kind, Offset a, Offset b) {
  switch (kind) {
    case ShapeKind.line:
      return [a, b];
    case ShapeKind.arrow:
      final v = b - a;
      final len = v.distance;
      if (len < 1e-6) return [a, b];
      final dir = v / len;
      final head = math.min(14.0, len * 0.4);
      const spread = 0.5; // ~28 degrees
      Offset rot(Offset d, double ang) => Offset(
        d.dx * math.cos(ang) - d.dy * math.sin(ang),
        d.dx * math.sin(ang) + d.dy * math.cos(ang),
      );
      final h1 = b - rot(dir, spread) * head;
      final h2 = b - rot(dir, -spread) * head;
      return [a, b, h1, b, h2];
    case ShapeKind.rectangle:
      final r = Rect.fromPoints(a, b);
      return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft];
    case ShapeKind.ellipse:
      return _ellipse(Rect.fromPoints(a, b));
    case ShapeKind.triangle:
      final r = Rect.fromPoints(a, b);
      return [
        r.bottomLeft,
        Offset(r.center.dx, r.top),
        r.bottomRight,
        r.bottomLeft,
      ];
  }
}

List<Offset> _ellipse(Rect r) {
  const n = 72;
  return [
    for (var i = 0; i <= n; i++)
      Offset(
        r.center.dx + r.width / 2 * math.cos(2 * math.pi * i / n),
        r.center.dy + r.height / 2 * math.sin(2 * math.pi * i / n),
      ),
  ];
}

double _pathLength(List<Offset> p) {
  var len = 0.0;
  for (var i = 1; i < p.length; i++) {
    len += (p[i] - p[i - 1]).distance;
  }
  return len;
}

/// Evenly spaced points along [p], so the statistics below do not depend on
/// how fast the user drew.
List<Offset> _resample(List<Offset> p, int n) {
  final total = _pathLength(p);
  if (total == 0) return List.filled(n, p.first);
  final step = total / (n - 1);
  final out = <Offset>[p.first];
  var carried = 0.0;
  for (var i = 1; i < p.length && out.length < n; i++) {
    var a = p[i - 1];
    final b = p[i];
    var seg = (b - a).distance;
    while (carried + seg >= step && out.length < n) {
      final t = (step - carried) / seg;
      a = Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
      out.add(a);
      seg = (b - a).distance;
      carried = 0;
    }
    carried += seg;
  }
  while (out.length < n) {
    out.add(p.last);
  }
  return out;
}

/// Recognises a hand-drawn line, ellipse or rectangle and returns the clean
/// polyline, or null when the stroke is not clearly one of them. Thresholds
/// are deliberately strict: a wrong snap is worse than no snap.
List<Offset>? snapShape(List<Offset> raw) {
  if (raw.length < 4) return null;
  final length = _pathLength(raw);
  if (length < 20) return null; // PDF points: too small to be a shape

  final first = raw.first, last = raw.last;
  final chord = (last - first).distance;

  // Straight line: every point close to the chord.
  if (chord > 0.85 * length && chord > 20) {
    final dir = (last - first) / chord;
    var maxDev = 0.0;
    for (final q in raw) {
      final v = q - first;
      final dev = (v.dx * dir.dy - v.dy * dir.dx).abs();
      if (dev > maxDev) maxDev = dev;
    }
    if (maxDev <= 0.06 * chord) return [first, last];
    return null;
  }

  // Closed shapes: the end must come back near the start.
  if (chord > 0.2 * length) return null;
  final pts = _resample(raw, 64);
  var l = double.infinity, t = double.infinity;
  var r = -double.infinity, b = -double.infinity;
  for (final q in pts) {
    l = math.min(l, q.dx);
    r = math.max(r, q.dx);
    t = math.min(t, q.dy);
    b = math.max(b, q.dy);
  }
  final w = r - l, h = b - t;
  if (w < 12 || h < 12) return null;
  final box = Rect.fromLTRB(l, t, r, b);

  // Ellipse: normalised radius stays close to 1.
  var ellErr = 0.0;
  for (final q in pts) {
    final nx = (q.dx - box.center.dx) / (w / 2);
    final ny = (q.dy - box.center.dy) / (h / 2);
    ellErr += (math.sqrt(nx * nx + ny * ny) - 1).abs();
  }
  ellErr /= pts.length;
  if (ellErr < 0.09) return _ellipse(box);

  // Rectangle: points hug the bounding box border, and every side is used.
  var rectErr = 0.0;
  final sideHit = [false, false, false, false];
  final tol = 0.08 * math.max(w, h);
  for (final q in pts) {
    final d = [q.dx - l, r - q.dx, q.dy - t, b - q.dy];
    final m = d.reduce(math.min);
    rectErr += m;
    for (var i = 0; i < 4; i++) {
      if (d[i] <= tol) sideHit[i] = true;
    }
  }
  rectErr /= pts.length * math.max(w, h);
  if (rectErr < 0.045 && sideHit.every((s) => s)) {
    return [
      box.topLeft,
      box.topRight,
      box.bottomRight,
      box.bottomLeft,
      box.topLeft,
    ];
  }
  return null;
}
