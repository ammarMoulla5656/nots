import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'cover_image.dart';

/// A cover as it stands on a shelf: a book's proportions, a thin spine on
/// one side, a soft shadow. [width] is taken from the space given when null.
/// A bar along the bottom shows how far the book has been read, and a round
/// badge in the corner says something about it (in the account, owned).
class BookCover extends StatelessWidget {
  const BookCover(
    this.cover, {
    super.key,
    this.width,
    this.progress,
    this.badge,
    this.ownId,
  });

  /// See [CoverImage.ownId].
  final String? ownId;

  /// Path of the cover on the server; empty for a plain cover.
  final String cover;
  final double? width;

  /// 0..1 share read, or null for no bar.
  final double? progress;
  final IconData? badge;

  /// A book's width to height.
  static const ratio = 500 / 723;

  static const _radius = BorderRadius.only(
    topLeft: Radius.circular(5),
    bottomLeft: Radius.circular(5),
    topRight: Radius.circular(9),
    bottomRight: Radius.circular(9),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = width ?? (box.maxWidth.isFinite ? box.maxWidth : 100.0);
        final h = w / ratio;
        return DecoratedBox(
          decoration: const BoxDecoration(
            borderRadius: _radius,
            // One small shadow: a screen full of covers stays light to draw
            // on weak phones.
            boxShadow: [
              BoxShadow(
                color: Color(0x33123A70),
                blurRadius: 6,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: _radius,
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CoverImage(cover, width: w, height: h, ownId: ownId),
                  // The spine.
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withValues(alpha: 0.22),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 4,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.28),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FractionallySizedBox(
                            widthFactor: progress!.clamp(0.0, 1.0),
                            child: const ColoredBox(
                              color: Brand.goldLight,
                              child: SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (badge != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: const BoxDecoration(
                          color: Color(0xBD0B2346),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(badge, size: 15, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
