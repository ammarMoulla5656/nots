import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'library_store.dart';

/// The volumes of a book that are in the library, as round numbers in a
/// small white card over the book (as in the Masdar app). The ring around
/// each number shows how far that volume has been read. Pops with the
/// chosen volume's entry.
Future<BookEntry?> showPartsPopup(
  BuildContext context, {
  required Rect anchor,
  required List<BookEntry> parts,
  required double? Function(BookEntry) progress,
}) {
  return showGeneralDialog<BookEntry>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'إغلاق',
    barrierColor: const Color(0x14000000),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (context, _, _) =>
        _PartsCard(anchor: anchor, parts: parts, progress: progress),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(
          begin: 0.94,
          end: 1.0,
        ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

class _PartsCard extends StatelessWidget {
  const _PartsCard({
    required this.anchor,
    required this.parts,
    required this.progress,
  });

  final Rect anchor;
  final List<BookEntry> parts;
  final double? Function(BookEntry) progress;

  static const _circle = 42.0;
  static const _gap = 12.0;
  static const _pad = 14.0;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final insets = MediaQuery.paddingOf(context);
    final maxW = screen.width - 32;
    final natural =
        parts.length * _circle + (parts.length - 1) * _gap + 2 * _pad;
    final w = math.min(natural, maxW);
    const h = _circle + 2 * 12.0;
    final left = (anchor.center.dx - w / 2).clamp(16.0, screen.width - 16 - w);
    final top = (anchor.center.dy - h / 2).clamp(
      insets.top + 8,
      screen.height - insets.bottom - 8 - h,
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: w,
          height: h,
          child: Material(
            color: Colors.white,
            elevation: 6,
            shadowColor: const Color(0x3316233A),
            borderRadius: BorderRadius.circular(16),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: _pad,
                vertical: 12,
              ),
              itemCount: parts.length,
              separatorBuilder: (_, _) => const SizedBox(width: _gap),
              itemBuilder: (context, i) {
                final b = parts[i];
                return _PartCircle(
                  number: b.part ?? i + 1,
                  share: progress(b),
                  size: _circle,
                  onTap: () => Navigator.pop(context, b),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PartCircle extends StatelessWidget {
  const _PartCircle({
    required this.number,
    required this.share,
    required this.size,
    required this.onTap,
  });

  final int number;
  final double? share;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'الجزء $number',
      child: InkResponse(
        onTap: onTap,
        radius: size / 2,
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(share ?? 0),
            child: Center(
              child: Text(
                '$number',
                style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF1B1B1F),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pale ring with a blue arc for the share read (a thin start when none).
class _RingPainter extends CustomPainter {
  _RingPainter(this.share);

  final double share;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.5;
    final r = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      r,
      0,
      2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = const Color(0xFFDCE3EC),
    );
    final sweep = 2 * math.pi * share.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    canvas.drawArc(
      r,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = Brand.blue,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.share != share;
}
