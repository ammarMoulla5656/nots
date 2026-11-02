import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'note_items.dart';

TextPainter _painterFor(NoteItem it, double scale) => TextPainter(
  text: TextSpan(
    text: it.text,
    style: TextStyle(
      color: Color(it.color),
      fontSize: it.fontSize * scale,
      height: 1.35,
    ),
  ),
  textDirection: isRtlText(it.text) ? TextDirection.rtl : TextDirection.ltr,
);

/// Width of the text itself: its longest line, wrapping at the item's width
/// (the wrap limit). The box and its frame hug the words, not the limit.
double _textWidth(NoteItem it, double scale) {
  final limit = (it.w <= 0 ? NoteItem.defaultTextWidth : it.w) * scale;
  final probe = _painterFor(it, scale)..layout(maxWidth: limit);
  final w = probe.width.ceilToDouble() + 1;
  probe.dispose();
  return math.min(w, limit);
}

TextPainter _layoutText(NoteItem it, double scale) {
  final width = _textWidth(it, scale);
  return _painterFor(it, scale)..layout(minWidth: width, maxWidth: width);
}

/// Height of a text item in PDF points (used for touch hit tests).
double textHeightPt(NoteItem it) {
  final tp = _layoutText(it, 1);
  final h = tp.height;
  tp.dispose();
  return h;
}

/// Width (PDF points) a text box needs for [text]: as wide as its longest
/// line, wrapping at [maxWidth]; so the box and its selection frame fit the
/// words instead of a fixed width.
double fitTextWidth(String text, double fontSize, {double maxWidth = 320}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, height: 1.35),
    ),
    textDirection: isRtlText(text) ? TextDirection.rtl : TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  final w = tp.width;
  tp.dispose();
  return (w + fontSize * 0.3).clamp(fontSize, maxWidth);
}

/// The area of [it] that reacts to touches, in PDF points.
Rect itemHitRect(NoteItem it) {
  if (it.kind != ItemKind.text) return it.hitRect();
  final tp = _layoutText(it, 1);
  final r = Rect.fromLTWH(it.x, it.y, tp.width, tp.height);
  tp.dispose();
  return r;
}

/// Whether a touch at [p] (PDF points) lands on [it]. Marks react only on
/// their own line rectangles, not on the box around all their lines.
bool itemContains(NoteItem it, Offset p) {
  if (it.kind == ItemKind.mark && it.rects.isNotEmpty) {
    return it.rects.any((r) => r.inflate(2).contains(p));
  }
  return itemHitRect(it).contains(p);
}

/// Paints text boxes, pins and tape of one page. [preview] stands in for the
/// stored item with the same id while the user moves or resizes it.
class ItemsPainter extends CustomPainter {
  ItemsPainter({
    required this.items,
    required this.scale,
    required this.preview,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<NoteItem> Function() items;
  final NoteItem? Function() preview;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final pv = preview();
    for (final stored in items()) {
      final it = (pv != null && pv.id == stored.id) ? pv : stored;
      canvas.save();
      switch (it.kind) {
        case ItemKind.text:
          final tp = _layoutText(it, scale);
          tp.paint(canvas, Offset(it.x * scale, it.y * scale));
          tp.dispose();
        case ItemKind.pin:
          _paintPin(canvas, it);
        case ItemKind.tape:
          _paintTape(canvas, it);
        case ItemKind.mark:
          _paintMark(canvas, it);
      }
      canvas.restore();
    }
  }

  Rect _px(Rect r) => Rect.fromLTRB(
    r.left * scale,
    r.top * scale,
    r.right * scale,
    r.bottom * scale,
  );

  void _paintMark(Canvas canvas, NoteItem it) {
    final color = Color(it.color);
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.4 * scale
      ..strokeCap = StrokeCap.round;
    for (final r in it.rects.map(_px)) {
      switch (it.style) {
        case MarkStyle.highlight:
          // Multiply: the page shows through as it is, so the letters keep
          // their colour and the highlight sits "under" them.
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              r.inflate(0.5 * scale),
              Radius.circular(2 * scale),
            ),
            Paint()
              ..color = color.withValues(alpha: 0.6)
              ..blendMode = BlendMode.multiply,
          );
        case MarkStyle.textColor:
          // Lighten keeps the lighter of page and colour: the dark letters
          // take the colour, the white page stays white.
          canvas.drawRect(
            r.inflate(0.4 * scale),
            Paint()
              ..color = color
              ..blendMode = BlendMode.lighten,
          );
        case MarkStyle.underline:
          canvas.drawLine(r.bottomLeft, r.bottomRight, line);
        case MarkStyle.strike:
          canvas.drawLine(r.centerLeft, r.centerRight, line);
        case MarkStyle.comment:
          // A commented word changes colour (lighten keeps the page white
          // and turns the dark letters to the colour), and gets a dotted
          // underline and a bubble.
          canvas.drawRect(
            r.inflate(0.4 * scale),
            Paint()
              ..color = color
              ..blendMode = BlendMode.lighten,
          );
          final y = r.bottom;
          final step = 3 * scale;
          for (var x = r.left; x < r.right; x += step * 2) {
            canvas.drawLine(
              Offset(x, y),
              Offset(math.min(x + step, r.right), y),
              line,
            );
          }
      }
    }
    // A comment bubble at the start of the marked words (their right end:
    // the books are Arabic) whenever the mark carries a comment.
    if (it.text.isNotEmpty || it.style == MarkStyle.comment) {
      final first = _px(
        it.rects.isEmpty
            ? Rect.fromLTWH(it.x, it.y, it.w, it.h)
            : it.rects.first,
      );
      final c = Offset(first.right + 3 * scale, first.top - 2 * scale);
      final rr = 4.5 * scale;
      canvas.drawCircle(c, rr, Paint()..color = Color(it.color));
      canvas.drawCircle(
        c,
        rr,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 * scale,
      );
    }
  }

  void _paintPin(Canvas canvas, NoteItem it) {
    final c = Offset(it.x * scale, it.y * scale);
    final r = NoteItem.pinRadius * scale;
    canvas.drawCircle(c, r, Paint()..color = Color(it.color));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * scale,
    );
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.4 * scale
      ..strokeCap = StrokeCap.round;
    for (final dy in [-3.5, 0.0, 3.5]) {
      canvas.drawLine(
        c + Offset(-4.5 * scale, dy * scale),
        c + Offset(4.5 * scale, dy * scale),
        line,
      );
    }
  }

  void _paintTape(Canvas canvas, NoteItem it) {
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(it.x * scale, it.y * scale, it.w * scale, it.h * scale),
      Radius.circular(3 * scale),
    );
    if (!it.revealed) {
      canvas.drawRRect(r, Paint()..color = Color(it.color));
    } else {
      canvas.drawRRect(
        r,
        Paint()..color = Color(it.color).withValues(alpha: 0.10),
      );
      canvas.drawRRect(
        r,
        Paint()
          ..color = Color(it.color).withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * scale,
      );
    }
  }

  @override
  bool shouldRepaint(ItemsPainter old) => old.scale != scale;
}
