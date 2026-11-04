import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'color_wheel.dart';

/// The colours on offer in every tool and in the text selection menu: one
/// list for the whole app, which the user can add to. Also remembers the
/// colour last used to mark text.
class ColorPalette extends ChangeNotifier {
  ColorPalette({List<int> colors = defaults, this.markColor = 0xFFD32F2F})
    : _colors = List.of(colors);

  /// No more colours than this are offered: a new one pushes out the last.
  static const maxColors = 4;

  /// The usual colours of the pen, the marks, comments and the highlighter.
  static const defaults = [0xFF1A1A1A, 0xFFD32F2F, 0xFF0D47A1, 0xFFFFEB3B];

  final List<int> _colors;
  File? _file;

  /// The colour text is marked with until another one is picked.
  int markColor;

  List<int> get colors => List.unmodifiable(_colors);

  /// Reads the saved list; until then, and from then on, changes are kept
  /// in [_file].
  Future<void> load() async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'prefs'),
    );
    await dir.create(recursive: true);
    final f = _file = File(p.join(dir.path, 'colors.json'));
    if (!await f.exists()) return;
    try {
      restore(await f.readAsString());
    } on FormatException {
      // A damaged file only loses the added colours.
    }
  }

  /// Takes over the state written by [encode].
  void restore(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final saved = ((j['colors'] as List?) ?? const []).cast<int>();
    if (saved.isNotEmpty) {
      _colors
        ..clear()
        ..addAll(saved.take(maxColors));
    }
    markColor = j['mark'] as int? ?? markColor;
    notifyListeners();
  }

  String encode() => jsonEncode({'colors': _colors, 'mark': markColor});

  void _changed() {
    notifyListeners();
    _file?.writeAsString(encode());
  }

  /// Adds [c] at the front of the list, unless it is already there.
  void add(int c) {
    if (_colors.contains(c)) return;
    _colors.insert(0, c);
    if (_colors.length > maxColors) {
      final out = _colors.removeLast();
      if (out == markColor) markColor = c;
    }
    _changed();
  }

  /// Takes [c] off the list; the last colour always stays.
  void remove(int c) {
    if (_colors.length < 2 || !_colors.remove(c)) return;
    if (c == markColor) markColor = _colors.first;
    _changed();
  }

  void setMarkColor(int c) {
    if (c == markColor) return;
    markColor = c;
    _changed();
  }
}

/// The colours as round buttons, after a "+" that adds one from the colour
/// wheel. A long press takes a colour off the list.
class ColorChoices extends StatelessWidget {
  const ColorChoices({
    super.key,
    required this.palette,
    required this.selected,
    required this.onPicked,
  });

  final ColorPalette palette;
  final int? selected;
  final ValueChanged<int> onPicked;

  Future<void> _add(BuildContext context) async {
    final c = await showColorWheelDialog(
      context,
      Color(selected ?? palette.markColor),
    );
    if (c == null) return;
    palette.add(c.toARGB32());
    onPicked(c.toARGB32());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: palette,
      builder: (context, _) {
        return Wrap(
          alignment: WrapAlignment.center,
          children: [
            _Dot(
              tooltip: 'إضافة لون',
              border: theme.colorScheme.outline,
              onTap: () => _add(context),
              child: Icon(
                Icons.add,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            for (final c in palette.colors)
              _Dot(
                color: Color(c),
                border: c == selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                ring: c == selected,
                onTap: () => onPicked(c),
                onLongPress: () => palette.remove(c),
              ),
          ],
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    this.color,
    required this.border,
    required this.onTap,
    this.onLongPress,
    this.ring = false,
    this.tooltip,
    this.child,
  });

  final Color? color;
  final Color border;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool ring;
  final String? tooltip;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final dot = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: border, width: ring ? 3 : 1),
          ),
          child: child,
        ),
      ),
    );
    return tooltip == null ? dot : Tooltip(message: tooltip!, child: dot);
  }
}

/// The list of colours in a small dialog. Returns the chosen colour, or null
/// when cancelled.
Future<int?> showColorListDialog(
  BuildContext context,
  ColorPalette palette,
  int current,
) {
  return showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      contentPadding: const EdgeInsets.all(14),
      content: SizedBox(
        width: 240,
        child: ColorChoices(
          palette: palette,
          selected: current,
          onPicked: (c) => Navigator.pop(context, c),
        ),
      ),
    ),
  );
}
