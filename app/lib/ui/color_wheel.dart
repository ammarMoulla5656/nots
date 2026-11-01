import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Hue and saturation of a touch at [p] on a wheel of [radius] centred at
/// [center]: the direction gives the hue (0° = red, to the right, turning
/// clockwise), the distance from the centre gives the saturation.
({double hue, double saturation}) wheelPick(
    Offset p, Offset center, double radius) {
  final d = p - center;
  final hue = (math.atan2(d.dy, d.dx) * 180 / math.pi + 360) % 360;
  final sat = radius <= 0 ? 0.0 : (d.distance / radius).clamp(0.0, 1.0);
  return (hue: hue, saturation: sat);
}

/// A round colour picker: hue around the circle, saturation from the
/// centre (white) to the rim. Brightness is shown as a dimming veil and is
/// changed with a separate slider.
class ColorWheel extends StatelessWidget {
  const ColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 240,
  });

  final HSVColor color;
  final ValueChanged<HSVColor> onChanged;
  final double size;

  void _pick(Offset local) {
    final r = size / 2;
    final hs = wheelPick(local, Offset(r, r), r);
    onChanged(color.withHue(hs.hue).withSaturation(hs.saturation));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanDown: (d) => _pick(d.localPosition),
      onPanUpdate: (d) => _pick(d.localPosition),
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _WheelPainter(color)),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.color);

  final HSVColor color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(colors: [
          for (var h = 0; h <= 360; h += 30)
            HSVColor.fromAHSV(1, h % 360.0, 1, 1).toColor(),
        ]).createShader(rect),
    );
    // White in the middle fading to full colour at the rim.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    // Brightness below 100% darkens the whole wheel.
    canvas.drawCircle(
        c, r, Paint()..color = Colors.black.withValues(alpha: 1 - color.value));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.black26
        ..style = PaintingStyle.stroke,
    );
    // Marker on the current colour.
    final a = color.hue * math.pi / 180;
    final m = c + Offset(math.cos(a), math.sin(a)) * (color.saturation * r);
    canvas.drawCircle(m, 9, Paint()..color = color.toColor());
    canvas.drawCircle(
      m,
      9,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      m,
      10.5,
      Paint()
        ..color = Colors.black45
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.color != color;
}

String _hex(Color c) =>
    c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

Color? _parseHex(String s) {
  final t = s.trim().replaceFirst('#', '');
  if (t.length != 6) return null;
  final v = int.tryParse(t, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Dialog with the colour wheel, a brightness slider, quick colours and a
/// HEX field. Returns the chosen colour, or null when cancelled.
Future<Color?> showColorWheelDialog(BuildContext context, Color initial) {
  var hsv = HSVColor.fromColor(initial);
  final hexController = TextEditingController(text: _hex(initial));
  const quick = [
    0xFF000000, 0xFF5D4037, 0xFFD32F2F, 0xFFEF6C00, 0xFFFFEB3B,
    0xFF2E7D32, 0xFF00897B, 0xFF1565C0, 0xFF6A1B9A, 0xFFFFFFFF,
  ];
  return showDialog<Color>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void set(HSVColor v, {bool updateHex = true}) => setState(() {
              hsv = v;
              if (updateHex) hexController.text = _hex(v.toColor());
            });
        return AlertDialog(
          title: const Text('اختر لوناً'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ColorWheel(color: hsv, onChanged: set),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.brightness_6_outlined, size: 20),
                      Expanded(
                        child: Slider(
                          value: hsv.value,
                          onChanged: (v) => set(hsv.withValue(v)),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final q in quick)
                        GestureDetector(
                          onTap: () => set(HSVColor.fromColor(Color(q))),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: Color(q),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.black26),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: initial,
                          borderRadius: const BorderRadiusDirectional.horizontal(
                              start: Radius.circular(8)),
                          border: Border.all(color: Colors.black26),
                        ),
                      ),
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: hsv.toColor(),
                          borderRadius: const BorderRadiusDirectional.horizontal(
                              end: Radius.circular(8)),
                          border: Border.all(color: Colors.black26),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: hexController,
                          textDirection: TextDirection.ltr,
                          decoration: const InputDecoration(
                            prefixText: '#',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (s) {
                            final c = _parseHex(s);
                            if (c != null) {
                              set(HSVColor.fromColor(c), updateHex: false);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(context, hsv.toColor()),
                child: const Text('موافق')),
          ],
        );
      },
    ),
  ).whenComplete(hexController.dispose);
}
