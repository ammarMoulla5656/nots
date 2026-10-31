import 'dart:math' as math;
import 'dart:ui';

/// Non-ink things placed on a page.
enum ItemKind { text, pin, tape }

class NoteItem {
  const NoteItem({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    this.w = 0,
    this.h = 0,
    this.text = '',
    this.color = 0xFF1A1A1A,
    this.fontSize = 14,
    this.revealed = false,
  });

  final int id;
  final ItemKind kind;

  /// Top-left corner in PDF points.
  final double x;
  final double y;

  /// Box size in PDF points: text wraps at [w]; tape uses both.
  final double w;
  final double h;
  final String text;
  final int color;

  /// Text size in PDF points.
  final double fontSize;

  /// Tape only: true when the covered content is uncovered.
  final bool revealed;

  static const defaultTextWidth = 220.0;
  static const pinRadius = 9.0;

  NoteItem copyWith({
    int? id,
    double? x,
    double? y,
    double? w,
    double? h,
    String? text,
    int? color,
    double? fontSize,
    bool? revealed,
  }) =>
      NoteItem(
        id: id ?? this.id,
        kind: kind,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        text: text ?? this.text,
        color: color ?? this.color,
        fontSize: fontSize ?? this.fontSize,
        revealed: revealed ?? this.revealed,
      );

  /// Area that reacts to touches, in PDF points. Pins get a little slack so
  /// they are easy to hit; text uses [measuredHeight] from layout.
  Rect hitRect({double measuredHeight = 0}) {
    switch (kind) {
      case ItemKind.pin:
        return Rect.fromCircle(
            center: Offset(x, y), radius: pinRadius + 4);
      case ItemKind.tape:
        return Rect.fromLTWH(x, y, w, h);
      case ItemKind.text:
        return Rect.fromLTWH(x, y, w, math.max(measuredHeight, fontSize * 1.4));
    }
  }
}

/// Text starting with an Arabic/Persian/Urdu letter is laid out right to left.
bool isRtlText(String s) {
  for (final r in s.runes) {
    if ((r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFEFF)) {
      return true;
    }
    final isLatin = (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
    if (isLatin) return false;
  }
  return false;
}
