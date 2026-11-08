import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// The kinds of paper a note can be made on, like a notebook's.
enum PaperKind {
  blank('بيضاء'),
  lined('مسطّرة'),
  grid('مربعات');

  const PaperKind(this.title);
  final String title;
}

/// Colours offered for the paper and for its lines.
const paperColors = [
  0xFFFFFFFF,
  0xFFFBF8F1,
  0xFFFFF4CC,
  0xFFE3EEFA,
  0xFFE4F3E8,
  0xFFF3E8F5,
  0xFF1D2636,
];
const lineColors = [
  0xFFD6CFBE,
  0xFFB9C7DA,
  0xFF9AA7B8,
  0xFF1C4F92,
  0xFFC8372D,
  0xFF2B2B2B,
];

/// One paper: its kind, the colour of the sheet and the colour of its lines.
/// A note keeps this as text (see [encode]) so every device draws it alike.
@immutable
class PaperStyle {
  const PaperStyle({
    this.kind = PaperKind.blank,
    this.paper = 0xFFFFFFFF,
    this.line = 0xFFD6CFBE,
  });

  final PaperKind kind;
  final int paper;
  final int line;

  /// Pages a new note starts with; more are added with the "+" button.
  static const pages = 1;

  PaperStyle copyWith({PaperKind? kind, int? paper, int? line}) => PaperStyle(
    kind: kind ?? this.kind,
    paper: paper ?? this.paper,
    line: line ?? this.line,
  );

  String encode() =>
      '${kind.name}|${paper.toRadixString(16)}|${line.toRadixString(16)}';

  /// Reads [encode]'s text; anything else is plain white paper.
  static PaperStyle parse(String s) {
    final p = s.split('|');
    if (p.length != 3) return const PaperStyle();
    final kind = PaperKind.values.where((k) => k.name == p[0]).firstOrNull;
    final paper = int.tryParse(p[1], radix: 16);
    final line = int.tryParse(p[2], radix: 16);
    if (kind == null || paper == null || line == null) {
      return const PaperStyle();
    }
    return PaperStyle(kind: kind, paper: paper, line: line);
  }

  @override
  bool operator ==(Object other) =>
      other is PaperStyle &&
      other.kind == kind &&
      other.paper == paper &&
      other.line == line;

  @override
  int get hashCode => Object.hash(kind, paper, line);
}

/// The paper's lines as segments in millimetres on an A4 sheet (210 x 297),
/// shared by the preview and by the PDF, so both show the same.
List<(double, double, double, double)> paperLines(PaperKind kind) {
  final out = <(double, double, double, double)>[];
  switch (kind) {
    case PaperKind.blank:
      break;
    case PaperKind.lined:
      for (var y = 24.0; y <= 285; y += 9) {
        out.add((14, y, 196, y));
      }
    case PaperKind.grid:
      for (var x = 7.0; x < 210; x += 7) {
        out.add((x, 0, x, 297));
      }
      for (var y = 7.0; y < 297; y += 7) {
        out.add((0, y, 210, y));
      }
  }
  return out;
}

/// Line width in millimetres.
double paperLineWidth(PaperKind kind) => kind == PaperKind.grid ? 0.3 : 0.5;

/// Paints a [PaperStyle] over the whole of its area.
class PaperPainter extends CustomPainter {
  const PaperPainter(this.style);

  final PaperStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(style.paper));
    final k = size.width / 210;
    final paint = Paint()
      ..color = Color(style.line)
      ..strokeWidth = paperLineWidth(style.kind) * k;
    for (final (x1, y1, x2, y2) in paperLines(style.kind)) {
      canvas.drawLine(Offset(x1 * k, y1 * k), Offset(x2 * k, y2 * k), paint);
    }
  }

  @override
  bool shouldRepaint(PaperPainter old) => old.style != style;
}

/// A small picture of a paper, in the proportions of a sheet.
class PaperPreview extends StatelessWidget {
  const PaperPreview(this.style, {super.key, this.selected = false});

  final PaperStyle style;
  final bool selected;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 210 / 297,
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? Brand.blue : Brand.line,
          width: selected ? 2.5 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(selected ? 9.5 : 11),
        child: RepaintBoundary(
          child: CustomPaint(
            painter: PaperPainter(style),
            isComplex: true,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}
