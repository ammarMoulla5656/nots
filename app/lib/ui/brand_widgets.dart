import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The app's mark: the Masdar icon (the app writes on its pages).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.24),
      boxShadow: const [
        BoxShadow(color: Color(0x40000000), blurRadius: 8, offset: Offset(0, 3)),
      ],
    ),
    clipBehavior: Clip.antiAlias,
    child: Image.asset('assets/images/masdar-icon.webp', fit: BoxFit.cover),
  );
}

/// Widest the content of a main screen grows: on a tablet it stays in a
/// centred column instead of stretching across the whole screen.
const contentMaxWidth = 940.0;

/// Side padding that keeps content within [contentMaxWidth] (and at least
/// [min] from the edge).
double sidePadding(BuildContext context, {double min = 18}) {
  final w = MediaQuery.sizeOf(context).width;
  return w > contentMaxWidth + 2 * min ? (w - contentMaxWidth) / 2 : min;
}

/// The blue header of the main screens: the Masdar gradient with its script
/// pattern, under the phone's status bar. Its lower edge is the rounded top
/// of the paper panel that follows.
class HeroHeader extends StatelessWidget {
  const HeroHeader({super.key, required this.child, this.bottom = 8});

  final Widget child;

  /// Space between [child] and the curve.
  final double bottom;

  static const curve = 24.0;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: Brand.heroGradient),
      child: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.09,
              child: Image.asset(
                'assets/images/tile-script.webp',
                repeat: ImageRepeat.repeat,
                scale: 1.7,
                fit: BoxFit.none,
                alignment: Alignment.topLeft,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              sidePadding(context),
              MediaQuery.paddingOf(context).top + 8,
              sidePadding(context),
              bottom + curve,
            ),
            child: child,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: curve + 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Brand.paper,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A round button on the blue header.
class HeroButton extends StatelessWidget {
  const HeroButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.dot = false,
    this.photo,
  });

  /// A picture shown in place of the icon (the account's).
  final String? photo;

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// A small green dot: the account is linked.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (photo != null)
                  ClipOval(
                    child: Image(
                      image: ResizeImage(NetworkImage(photo!), width: 96),
                      width: 32,
                      height: 32,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Icon(icon, size: 21, color: Colors.white),
                    ),
                  )
                else
                  Icon(icon, size: 21, color: Colors.white),
                if (dot && photo == null)
                  Positioned(
                    top: 8,
                    left: 9,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: const Color(0xFF58D39A),
                        shape: BoxShape.circle,
                        border: Border.all(color: Brand.blue, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted glass: a blurred, semi-transparent white surface.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = EdgeInsets.zero,
    this.opacity = 0.78,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const [
          BoxShadow(color: Color(0x1416233A), blurRadius: 24, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x0F16233A), blurRadius: 2, offset: Offset(0, 1)),
        ],
      ),
      // No blur behind: blurring what scrolls under the bars costs every
      // frame, and weak phones stutter. An almost opaque surface looks the
      // same on a page.
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Brand.surface.withValues(alpha: math.max(opacity, 0.95)),
          borderRadius: r,
          border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// The eight-pointed star of the "new" button.
class StarButton extends StatelessWidget {
  const StarButton({super.key, required this.onPressed, this.size = 64});

  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'جديد',
      child: GestureDetector(
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _StarPainter(),
            child: const Center(
              child: Icon(Icons.add, color: Colors.white, size: 28),
            ),
          ),
        ),
      ),
    );
  }
}

class _StarPainter extends CustomPainter {
  static Path path(Size s) {
    double x(double v) => v / 100 * s.width;
    double y(double v) => v / 100 * s.height;
    final pts = <List<double>>[
      [50, 2], [64, 16], [84, 16], [84, 36], [98, 50], [84, 64], [84, 84],
      [64, 84], [50, 98], [36, 84], [16, 84], [16, 64], [2, 50], [16, 36],
      [16, 16], [36, 16],
    ];
    final p = Path()..moveTo(x(pts[0][0]), y(pts[0][1]));
    for (final q in pts.skip(1)) {
      p.lineTo(x(q[0]), y(q[1]));
    }
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = path(size);
    canvas.drawShadow(p, const Color(0xFF0C2850), 6, true);
    canvas.drawPath(p, Paint()..color = Brand.blueDeep);
  }

  @override
  bool shouldRepaint(_StarPainter old) => false;
}

/// A section title with an optional action on the other side.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.count, this.top = 22});

  final String title;
  final int? count;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 12),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            if (count != null)
              TextSpan(
                text: '  ($count)',
                style: TextStyle(
                  fontSize: 13,
                  color: Brand.muted,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A row of round-cornered category buttons that scrolls sideways.
class Pills extends StatelessWidget {
  const Pills({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: labels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final on = labels[i] == selected;
          return GestureDetector(
            onTap: () => onSelected(labels[i]),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? Brand.blue : Brand.surface,
                borderRadius: BorderRadius.circular(19),
                border: on ? null : Border.all(color: Brand.line),
                boxShadow: on
                    ? const [
                        BoxShadow(
                          color: Color(0x4D1C4F92),
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: 14,
                  color: on ? Colors.white : Brand.muted,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A small square button beside the pills and search (sort, filter).
class SquareButton extends StatelessWidget {
  const SquareButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.on = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool on;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: on ? Brand.blue : Brand.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: on ? null : Border.all(color: Brand.line),
            ),
            child: Icon(icon, size: 20, color: on ? Colors.white : Brand.ink),
          ),
        ),
      ),
    );
  }
}

/// The handle at the top of a bottom sheet and its title.
class SheetHeader extends StatelessWidget {
  const SheetHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(top: 8, bottom: 12),
            decoration: BoxDecoration(
              color: Brand.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
          ),
      ],
    );
  }
}

/// Opens [builder] as the app's bottom sheet: paper, rounded, with a handle.
Future<T?> showNotsSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool tall = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: const Color(0x6B091630),
    constraints: const BoxConstraints(maxWidth: 600),
    builder: tall
        ? (c) => FractionallySizedBox(heightFactor: 0.88, child: builder(c))
        : builder,
  );
}
