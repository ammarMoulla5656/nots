import 'package:flutter/material.dart';

import '../ui/brand_widgets.dart';
import '../ui/theme.dart';

/// The floating bar that moves between the three tabs, and the star beside
/// it that starts a new paper. Place it in a [Stack] over the tabs.
class HomeBar extends StatelessWidget {
  const HomeBar({
    super.key,
    required this.tab,
    required this.onTab,
    required this.onNew,
    this.busy = false,
  });

  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onNew;

  /// A paper or a book is being made: the star waits.
  final bool busy;

  static const _tabs = [
    (Icons.collections_bookmark_outlined, 'كتبي'),
    (Icons.storefront_outlined, 'الكتب'),
    (Icons.description_outlined, 'ملاحظاتي'),
  ];

  Widget _item(int i) {
    final on = tab == i;
    final (icon, label) = _tabs[i];
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTab(i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 54,
          decoration: BoxDecoration(
            color: on ? Brand.blue : Colors.transparent,
            borderRadius: BorderRadius.circular(19),
            boxShadow: on
                ? const [
                    BoxShadow(
                      color: Color(0x571C4F92),
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 23, color: on ? Colors.white : Brand.muted),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.3,
                  color: on ? Colors.white : Brand.muted,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final wide = w >= 700;
    final bottom = MediaQuery.paddingOf(context).bottom + 14;
    final navLeft = wide ? (w - 420) / 2 : 90.0;
    final navRight = wide ? (w - 420) / 2 : 14.0;
    return Stack(
      children: [
        Positioned(
          left: navLeft,
          right: navRight,
          bottom: bottom,
          height: 64,
          child: Glass(
            radius: 24,
            padding: const EdgeInsets.all(5),
            child: Row(children: [for (var i = 0; i < _tabs.length; i++) _item(i)]),
          ),
        ),
        Positioned(
          left: wide ? navLeft - 78 : 14,
          bottom: bottom,
          child: busy
              ? const SizedBox(
                  width: 64,
                  height: 64,
                  child: Center(child: CircularProgressIndicator()),
                )
              : StarButton(onPressed: onNew),
        ),
      ],
    );
  }
}
