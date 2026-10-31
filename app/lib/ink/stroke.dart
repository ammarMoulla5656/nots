import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'note_items.dart';

/// Append new values only: the index is stored in saved files.
enum InkTool { pen, highlighter, pencil, calligraphy }

/// One sampled point of a stroke. [x] and [y] are in PDF points (1/72 inch),
/// so a stroke looks identical at any zoom level or screen size.
class StrokePoint {
  const StrokePoint(this.x, this.y, this.pressure, this.t);

  final double x;
  final double y;

  /// 0..1. Constant 0.5 for mouse and finger input.
  final double pressure;

  /// Milliseconds since the stroke started (kept for audio sync later).
  final int t;
}

class Stroke {
  Stroke({
    required this.id,
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
  });

  final int id;
  final InkTool tool;

  /// ARGB colour value.
  final int color;

  /// Base width in PDF points.
  final double width;
  final List<StrokePoint> points;

  Stroke copyWith({int? id, int? color, List<StrokePoint>? points}) => Stroke(
        id: id ?? this.id,
        tool: tool,
        color: color ?? this.color,
        width: width,
        points: points ?? this.points,
      );

  Stroke translated(double dx, double dy) => copyWith(points: [
        for (final p in points) StrokePoint(p.x + dx, p.y + dy, p.pressure, p.t),
      ]);

  /// Bounding box in PDF points, including half the stroke width.
  ui.Rect get bounds {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in points) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      maxX = math.max(maxX, p.x);
      maxY = math.max(maxY, p.y);
    }
    if (points.isEmpty) return ui.Rect.zero;
    return ui.Rect.fromLTRB(minX, minY, maxX, maxY).inflate(width / 2);
  }

  /// Distance from [x],[y] to the nearest part of the stroke, minus half the
  /// stroke width. Negative or zero means the point touches the stroke.
  double distanceTo(double x, double y) {
    if (points.isEmpty) return double.infinity;
    var best = double.infinity;
    if (points.length == 1) {
      best = math.sqrt(_sq(x - points[0].x) + _sq(y - points[0].y));
    } else {
      for (var i = 1; i < points.length; i++) {
        final d = _segmentDistance(x, y, points[i - 1], points[i]);
        if (d < best) best = d;
      }
    }
    return best - width / 2;
  }

  static double _sq(double v) => v * v;

  static double _segmentDistance(
      double px, double py, StrokePoint a, StrokePoint b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final lenSq = dx * dx + dy * dy;
    var t = lenSq == 0 ? 0.0 : ((px - a.x) * dx + (py - a.y) * dy) / lenSq;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + t * dx;
    final cy = a.y + t * dy;
    return math.sqrt(_sq(px - cx) + _sq(py - cy));
  }
}

/// Compact binary format for strokes: coordinates are quantised to 1/100 of a
/// PDF point (about 0.0035 mm) and stored as zig-zag varint deltas.
class StrokeCodec {
  static const _magic = [0x4E, 0x4F, 0x54, 0x53]; // "NOTS"
  // Version 1: strokes only. Version 2 appends text boxes, pins and tape.
  static const _version = 2;
  static const _scale = 100.0;

  static Uint8List encodeDocument(
    Map<int, List<Stroke>> pages,
    int nextStrokeId, {
    Map<int, List<NoteItem>> items = const {},
  }) {
    final w = _Writer();
    for (final b in _magic) {
      w.byte(b);
    }
    w.byte(_version);
    w.varint(nextStrokeId);
    final used = pages.entries.where((e) => e.value.isNotEmpty).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    w.varint(used.length);
    for (final e in used) {
      w.varint(e.key);
      w.varint(e.value.length);
      for (final s in e.value) {
        _writeStroke(w, s);
      }
    }
    final usedItems = items.entries.where((e) => e.value.isNotEmpty).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    w.varint(usedItems.length);
    for (final e in usedItems) {
      w.varint(e.key);
      w.varint(e.value.length);
      for (final it in e.value) {
        _writeItem(w, it);
      }
    }
    return w.takeBytes();
  }

  static ({
    Map<int, List<Stroke>> pages,
    int nextStrokeId,
    Map<int, List<NoteItem>> items,
  }) decodeDocument(Uint8List data) {
    final r = _Reader(data);
    for (final b in _magic) {
      if (r.byte() != b) throw const FormatException('Not a NOTS ink file');
    }
    final version = r.byte();
    if (version != 1 && version != _version) {
      throw FormatException('Unsupported ink file version $version');
    }
    final nextId = r.varint();
    final pageCount = r.varint();
    final pages = <int, List<Stroke>>{};
    for (var i = 0; i < pageCount; i++) {
      final pageNumber = r.varint();
      final strokeCount = r.varint();
      pages[pageNumber] = [for (var j = 0; j < strokeCount; j++) _readStroke(r)];
    }
    final items = <int, List<NoteItem>>{};
    if (version >= 2) {
      final itemPages = r.varint();
      for (var i = 0; i < itemPages; i++) {
        final pageNumber = r.varint();
        final count = r.varint();
        items[pageNumber] = [for (var j = 0; j < count; j++) _readItem(r)];
      }
    }
    return (pages: pages, nextStrokeId: nextId, items: items);
  }

  static void _writeItem(_Writer w, NoteItem it) {
    w.varint(it.id);
    w.byte(it.kind.index);
    w.zigzag((it.x * _scale).round());
    w.zigzag((it.y * _scale).round());
    w.varint((it.w * _scale).round());
    w.varint((it.h * _scale).round());
    w.uint32(it.color);
    w.varint((it.fontSize * _scale).round());
    w.byte(it.revealed ? 1 : 0);
    final text = utf8.encode(it.text);
    w.varint(text.length);
    w.bytes(text);
  }

  static NoteItem _readItem(_Reader r) {
    final id = r.varint();
    final kind = ItemKind.values[r.byte()];
    final x = r.zigzag() / _scale;
    final y = r.zigzag() / _scale;
    final w = r.varint() / _scale;
    final h = r.varint() / _scale;
    final color = r.uint32();
    final fontSize = r.varint() / _scale;
    final revealed = r.byte() == 1;
    final text = utf8.decode(r.bytes(r.varint()));
    return NoteItem(
      id: id,
      kind: kind,
      x: x,
      y: y,
      w: w,
      h: h,
      text: text,
      color: color,
      fontSize: fontSize,
      revealed: revealed,
    );
  }

  static void _writeStroke(_Writer w, Stroke s) {
    w.varint(s.id);
    w.byte(s.tool.index);
    w.uint32(s.color);
    w.varint((s.width * _scale).round());
    w.varint(s.points.length);
    var px = 0, py = 0, pt = 0;
    for (final p in s.points) {
      final qx = (p.x * _scale).round();
      final qy = (p.y * _scale).round();
      w.zigzag(qx - px);
      w.zigzag(qy - py);
      w.byte((p.pressure.clamp(0.0, 1.0) * 255).round());
      w.varint(math.max(0, p.t - pt));
      px = qx;
      py = qy;
      pt = math.max(pt, p.t);
    }
  }

  static Stroke _readStroke(_Reader r) {
    final id = r.varint();
    final tool = InkTool.values[r.byte()];
    final color = r.uint32();
    final width = r.varint() / _scale;
    final count = r.varint();
    final points = <StrokePoint>[];
    var qx = 0, qy = 0, t = 0;
    for (var i = 0; i < count; i++) {
      qx += r.zigzag();
      qy += r.zigzag();
      final pressure = r.byte() / 255;
      t += r.varint();
      points.add(StrokePoint(qx / _scale, qy / _scale, pressure, t));
    }
    return Stroke(id: id, tool: tool, color: color, width: width, points: points);
  }
}

class _Writer {
  final _bytes = BytesBuilder(copy: false);

  void byte(int v) => _bytes.addByte(v & 0xFF);

  void bytes(List<int> v) => _bytes.add(v);

  void uint32(int v) {
    byte(v >> 24);
    byte(v >> 16);
    byte(v >> 8);
    byte(v);
  }

  void varint(int v) {
    assert(v >= 0);
    while (v >= 0x80) {
      byte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    byte(v);
  }

  void zigzag(int v) => varint(v >= 0 ? v << 1 : ((-v) << 1) - 1);

  Uint8List takeBytes() => _bytes.takeBytes();
}

class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  var _pos = 0;

  int byte() {
    if (_pos >= _data.length) throw const FormatException('Unexpected end of ink data');
    return _data[_pos++];
  }

  int uint32() => (byte() << 24) | (byte() << 16) | (byte() << 8) | byte();

  Uint8List bytes(int n) {
    if (n < 0 || _pos + n > _data.length) {
      throw const FormatException('Unexpected end of ink data');
    }
    final out = Uint8List.sublistView(_data, _pos, _pos + n);
    _pos += n;
    return out;
  }

  int varint() {
    var result = 0, shift = 0;
    while (true) {
      final b = byte();
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('Bad varint in ink data');
    }
  }

  int zigzag() {
    final v = varint();
    return v.isEven ? v >> 1 : -((v + 1) >> 1);
  }
}
