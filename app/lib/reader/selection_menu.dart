import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/color_palette.dart';

/// One button of the [SelectionMenu]. [onPressed] gets the colour picked in
/// the menu, or null when none was.
typedef SelectionAction = ({String label, ValueChanged<int?> onPressed});

/// The menu over selected text: the colours on top, the actions under them.
/// The colour picked here goes to the action pressed next.
class SelectionMenu extends StatefulWidget {
  const SelectionMenu({
    super.key,
    required this.palette,
    required this.actions,
  });

  final ColorPalette palette;
  final List<SelectionAction> actions;

  @override
  State<SelectionMenu> createState() => _SelectionMenuState();
}

class _SelectionMenuState extends State<SelectionMenu> {
  int? _picked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      // The viewer places the menu without a width limit.
      width: math.min(330, MediaQuery.sizeOf(context).width - 16),
      child: Material(
        elevation: 6,
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
              child: ColorChoices(
                palette: widget.palette,
                selected: _picked ?? widget.palette.markColor,
                onPicked: (c) => setState(() => _picked = c),
              ),
            ),
            const Divider(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [
                  for (final a in widget.actions)
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => a.onPressed(_picked),
                      child: Text(a.label),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
