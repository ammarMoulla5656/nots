import 'package:flutter/material.dart';

import 'note_items.dart';

TextPainter _layoutText(NoteItem it, double scale) {
  final tp = TextPainter(
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
  final width = (it.w <= 0 ? NoteItem.defaultTextWidth : it.w) * scale;
  tp.layout(minWidth: width, maxWidth: width);
  return tp;
}

/// Height of a text item in PDF points (used for touch hit tests).
double textHeightPt(NoteItem it) {
  final tp = _layoutText(it, 1);
  final h = tp.height;
  tp.dispose();
  return h;
}

/// The area of [it] that reacts to touches, in PDF points.
Rect itemHitRect(NoteItem it) => it.hitRect(
    measuredHeight: it.kind == ItemKind.text ? textHeightPt(it) : 0);

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
      }
      canvas.restore();
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
          r, Paint()..color = Color(it.color).withValues(alpha: 0.10));
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
