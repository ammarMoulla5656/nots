import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../book/book_text.dart';
import 'search_page.dart';

/// Marks where the search hits sit on one PDF page: the current hit in
/// strong orange, the other hits on the page in light yellow. Needs a book
/// text with a word map (every word's place); draws nothing otherwise.
class SearchHighlight extends StatelessWidget {
  const SearchHighlight({
    super.key,
    required this.search,
    required this.book,
    required this.pdfPage,
    required this.pageWidthPt,
  });

  final ValueListenable<SearchPick?> search;
  final BookText book;
  final int pdfPage;
  final double pageWidthPt;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<SearchPick?>(
        valueListenable: search,
        builder: (context, pick, _) {
          if (pick == null || !book.embedded) return const SizedBox.shrink();
          final bookPage = book.bookPageOf(pdfPage);
          final others = <Rect>[];
          var current = const <Rect>[];
          for (var i = 0; i < pick.hits.length; i++) {
            final h = pick.hits[i];
            if (h.page != bookPage) continue;
            final rects = book.hitRects(h);
            if (i == pick.index) {
              current = rects;
            } else {
              others.addAll(rects);
            }
          }
          if (current.isEmpty && others.isEmpty) return const SizedBox.shrink();
          return CustomPaint(
            size: Size.infinite,
            painter: _HitPainter(others, current, pageWidthPt),
          );
        },
      ),
    );
  }
}

class _HitPainter extends CustomPainter {
  _HitPainter(this.others, this.current, this.pageWidthPt);

  final List<Rect> others;
  final List<Rect> current;
  final double pageWidthPt;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / pageWidthPt;
    // Multiply keeps the letters dark under the colour, like a marker pen.
    final light = Paint()
      ..color = const Color(0x99FFEB3B)
      ..blendMode = BlendMode.multiply;
    final strong = Paint()
      ..color = const Color(0xCCFF9800)
      ..blendMode = BlendMode.multiply;
    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFE65100);
    Rect scaled(Rect r) => Rect.fromLTRB(
      r.left * s,
      r.top * s,
      r.right * s,
      r.bottom * s,
    ).inflate(1);
    for (final r in others) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(scaled(r), const Radius.circular(2)),
        light,
      );
    }
    for (final r in current) {
      final rr = RRect.fromRectAndRadius(scaled(r), const Radius.circular(3));
      canvas.drawRRect(rr, strong);
      canvas.drawRRect(rr.inflate(1.5), frame);
    }
  }

  @override
  bool shouldRepaint(_HitPainter old) =>
      !listEquals(old.others, others) ||
      !listEquals(old.current, current) ||
      old.pageWidthPt != pageWidthPt;
}
