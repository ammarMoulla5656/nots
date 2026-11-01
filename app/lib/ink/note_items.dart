import 'dart:math' as math;
import 'dart:ui';

/// Non-ink things placed on a page. Append new values only: the index is
/// stored in saved files.
enum ItemKind { text, pin, tape, mark }

/// How a mark on PDF words looks. Append new values only (stored in files).
enum MarkStyle { highlight, underline, strike, comment }

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
    this.style = MarkStyle.highlight,
    this.rects = const [],
    this.quote = '',
  });

  final int id;
  final ItemKind kind;

  /// Top-left corner in PDF points.
  final double x;
  final double y;

  /// Box size in PDF points: text wraps at [w]; tape and marks use both.
  final double w;
  final double h;

  /// Typed text: the text box content, the pin note, or a mark's comment.
  final String text;
  final int color;

  /// Text size in PDF points.
  final double fontSize;

  /// Tape only: true when the covered content is uncovered.
  final bool revealed;

  /// Marks only: highlight, underline, strike-through or comment.
  final MarkStyle style;

  /// Marks only: one rectangle per line of the marked PDF words.
  final List<Rect> rects;

  /// Marks only: the PDF words that were marked (kept for search and for
  /// linking to the book text later).
  final String quote;

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
    MarkStyle? style,
    List<Rect>? rects,
    String? quote,
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
        style: style ?? this.style,
        rects: rects ?? this.rects,
        quote: quote ?? this.quote,
      );

  /// Area that reacts to touches, in PDF points. Pins get a little slack so
  /// they are easy to hit; text uses [measuredHeight] from layout.
  Rect hitRect({double measuredHeight = 0}) {
    switch (kind) {
      case ItemKind.pin:
        return Rect.fromCircle(center: Offset(x, y), radius: pinRadius + 4);
      case ItemKind.tape:
      case ItemKind.mark:
        return Rect.fromLTWH(x, y, w, h);
      case ItemKind.text:
        return Rect.fromLTWH(
            x, y, w, math.max(measuredHeight, fontSize * 1.4));
    }
  }

  /// A mark covering [lineRects] (PDF points, top-left origin).
  static NoteItem mark({
    required int id,
    required List<Rect> lineRects,
    required MarkStyle style,
    required int color,
    String quote = '',
    String comment = '',
  }) {
    var box = lineRects.first;
    for (final r in lineRects.skip(1)) {
      box = box.expandToInclude(r);
    }
    return NoteItem(
      id: id,
      kind: ItemKind.mark,
      x: box.left,
      y: box.top,
      w: box.width,
      h: box.height,
      color: color,
      style: style,
      rects: lineRects,
      quote: quote,
      text: comment,
    );
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
