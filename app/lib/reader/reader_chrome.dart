import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ink/ink_document.dart';
import '../ink/note_items.dart';
import '../ink/selection.dart';
import '../ink/shapes.dart';
import '../ink/stroke.dart';
import '../ink/tool_controller.dart';
import '../ui/brand_widgets.dart';
import '../ui/color_palette.dart';
import '../ui/theme.dart';
import 'tool_layout.dart';

/// What the little panel under the bars is showing.
enum ReaderPop { none, options, box }

/// Width at which the bars fit on one line (a tablet).
const wideBars = 700.0;

/// A square button on a glass bar.
class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.color,
    this.fill = false,
    this.size = 40,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// The blue "this tool is on" look.
  final bool selected;
  final Color? color;

  /// The icon is drawn solid (a bookmark that is set).
  final bool fill;
  final double size;

  @override
  Widget build(BuildContext context) {
    final off = onPressed == null;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: selected ? Brand.blue : Colors.transparent,
            borderRadius: BorderRadius.circular(selected ? 14 : 12),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x571C4F92),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: 21,
            color: selected
                ? Colors.white
                : (color ?? (off ? Brand.line : Brand.ink)),
          ),
        ),
      ),
    );
  }
}

/// The back button, the Masdar button, and the group of buttons on the other
/// side; with the tool row between them on a wide screen and under them on a
/// narrow one.
class ReaderBars extends StatelessWidget {
  const ReaderBars({
    super.key,
    required this.tools,
    required this.layout,
    required this.document,
    required this.selection,
    required this.isBook,
    required this.bookmarked,
    required this.onBack,
    required this.onMasdar,
    required this.onHistory,
    required this.onToc,
    required this.onSearch,
    required this.onBookmark,
    required this.onMore,
    required this.onTool,
    required this.onBox,
    required this.boxOpen,
    this.inMasdar = false,
  });

  final ToolController tools;
  final ToolLayout layout;
  final InkDocument document;
  final SelectionController selection;

  /// A book (with contents and search), not a note.
  final bool isBook;
  final bool bookmarked;
  final VoidCallback onBack;
  final VoidCallback onMasdar;
  final VoidCallback onHistory;
  final VoidCallback onToc;
  final VoidCallback onSearch;
  final VoidCallback onBookmark;
  final VoidCallback onMore;
  final void Function(ReaderTool) onTool;
  final VoidCallback onBox;
  final bool boxOpen;

  /// The book is in the Masdar app: its logo shows and opens the same page.
  final bool inMasdar;

  bool _active(ReaderTool t) {
    final m = t.mode;
    if (m != null) return tools.mode == m;
    return t == ReaderTool.ruler && tools.ruler.value != null;
  }

  Widget _toolRow(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([tools, layout, document, tools.ruler]),
      builder: (context, _) {
        final bar = _barTools;
        final inBox = layout.box.where((t) => _active(t)).firstOrNull;
        return Glass(
          radius: 16,
          padding: const EdgeInsets.all(3),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in bar)
                  BarButton(
                    icon: t.icon,
                    tooltip: t.label,
                    selected: _active(t),
                    onPressed: () => onTool(t),
                  ),
                BarButton(
                  icon: inBox?.icon ?? Icons.apps_rounded,
                  tooltip: 'مربع الأدوات',
                  selected: inBox != null || boxOpen,
                  onPressed: onBox,
                ),
                Container(
                  width: 1,
                  height: 22,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  color: Brand.line,
                ),
                BarButton(
                  icon: Icons.undo,
                  tooltip: 'تراجع',
                  color: Brand.gold,
                  onPressed: document.canUndo ? document.undo : null,
                ),
                BarButton(
                  icon: Icons.redo,
                  tooltip: 'إعادة',
                  color: Brand.gold,
                  onPressed: document.canRedo ? document.redo : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _group() => Glass(
    radius: 15,
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BarButton(
          icon: Icons.schedule,
          tooltip: 'آخر ١٠ كتب',
          size: 39,
          onPressed: onHistory,
        ),
        if (isBook) ...[
          BarButton(
            icon: Icons.format_list_bulleted,
            tooltip: 'الفهرس',
            size: 39,
            onPressed: onToc,
          ),
          BarButton(
            icon: Icons.search,
            tooltip: 'بحث',
            size: 39,
            onPressed: onSearch,
          ),
        ],
        BarButton(
          icon: bookmarked ? Icons.bookmark : Icons.bookmark_border,
          tooltip: bookmarked ? 'إزالة علامة الصفحة' : 'وضع علامة على الصفحة',
          size: 39,
          color: bookmarked ? Brand.gold : null,
          onPressed: onBookmark,
        ),
        BarButton(
          icon: Icons.more_horiz,
          tooltip: 'المزيد',
          size: 39,
          onPressed: onMore,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideBars;
    final back = Glass(
      radius: 15,
      child: BarButton(
        icon: Icons.arrow_back,
        tooltip: 'رجوع',
        size: 44,
        color: Brand.blue,
        onPressed: onBack,
      ),
    );
    final masdar = inMasdar
        ? Tooltip(
            message: 'فتح في المصدر',
            child: GestureDetector(
              onTap: onMasdar,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x2916233A),
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/images/masdar-icon.webp',
                  fit: BoxFit.cover,
                ),
              ),
            ),
          )
        : const SizedBox.shrink();
    return ListenableBuilder(
      // Tools put into the bar or taken out change what fits.
      listenable: layout,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          // The real width of the screen decides: the tools go on the top
          // row only when they fit there beside everything else; otherwise
          // they have a row of their own, and if even that is too narrow
          // they scroll inside it. Nothing is ever pushed off the screen.
          final room = box.maxWidth - 20;
          final tools = _toolRowWidth();
          final headWidth = 44 + (inMasdar ? 6 + 44 : 0) + _groupWidth();
          final oneRow = wide && headWidth + tools + 2 * 16 <= room;
          final head = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              back,
              if (inMasdar) ...[const SizedBox(width: 6), masdar],
              const Spacer(),
              if (oneRow) ...[_toolRow(context), const Spacer()],
              _group(),
            ],
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                if (!oneRow) ...[
                  const SizedBox(height: 6),
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: room),
                      child: tools > room
                          ? _fadeEnds(_toolRow(context))
                          : _toolRow(context),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// Tools shown in the bar (some are for books only).
  /// The tools in the bar: the user's, and for a note always the text tool
  /// too (a note is written on, so typing is at hand beside the pen).
  List<ReaderTool> get _barTools => [
    for (final t in layout.bar)
      if (isBook || !t.forBooksOnly) t,
    if (!isBook && !layout.bar.contains(ReaderTool.text)) ReaderTool.text,
  ];

  int get _barCount => _barTools.length;

  /// Width of the tools' row: its buttons, the box, the line, undo and
  /// redo, and the frame around them.
  double _toolRowWidth() => (_barCount + 3) * 40 + 5 + 6;

  /// Width of the group of buttons on the other side.
  double _groupWidth() => (isBook ? 5 : 3) * 39 + 4;

  /// Both ends fade a little: a row that scrolls shows there is more.
  Widget _fadeEnds(Widget child) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (r) => const LinearGradient(
      colors: [
        Colors.transparent,
        Colors.black,
        Colors.black,
        Colors.transparent,
      ],
      stops: [0, 0.05, 0.95, 1],
    ).createShader(r),
    child: child,
  );
}

/// The options of the chosen tool: its kinds, its colours, its size.
class ToolOptions extends StatelessWidget {
  const ToolOptions({
    super.key,
    required this.tools,
    required this.palette,
    required this.fingerDraws,
    required this.onFinger,
    required this.onColor,
  });

  final ToolController tools;
  final ColorPalette palette;
  final bool fingerDraws;
  final ValueChanged<bool> onFinger;

  /// A colour was picked: the panel can go.
  final VoidCallback onColor;

  Widget _kinds<T>(List<(T, String)> items, T current, ValueChanged<T> pick) =>
      Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Brand.wash,
          borderRadius: BorderRadius.circular(13),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (v, label) in items)
                GestureDetector(
                  onTap: () => pick(v),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == current ? Brand.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: v == current
                          ? const [
                              BoxShadow(
                                color: Color(0x1F000000),
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        color: v == current ? Brand.blue : Brand.muted,
                        fontWeight: v == current ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _toggle(String label, bool on, ValueChanged<bool> set) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      // A long label wraps instead of pushing the switch off the panel.
      Flexible(child: Text(label, style: const TextStyle(fontSize: 13))),
      const SizedBox(width: 12),
      SizedBox(
        height: 28,
        child: FittedBox(
          child: Switch(value: on, onChanged: set),
        ),
      ),
    ],
  );

  /// The three usual widths, as strokes of growing thickness, and a slider
  /// for the exact one.
  Widget _widths(BuildContext context) {
    final range = tools.widthRange;
    final mode = tools.mode;
    final presets = switch (mode) {
      ToolMode.highlighter => const [8.0, 16.0, 28.0],
      ToolMode.text => const [10.0, 16.0, 28.0],
      _ => const [0.8, 1.8, 3.6],
    };
    final w = tools.width.clamp(range.min, range.max);
    final ratio = math.log(range.max / range.min);
    final t = math.log(w / range.min) / ratio;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final v in presets)
              GestureDetector(
                onTap: () => tools.setWidth(v),
                child: Container(
                  width: 40,
                  height: 32,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (tools.width - v).abs() < 0.01
                        ? Brand.tint
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: mode == ToolMode.text
                      ? Text(
                          'أ',
                          style: TextStyle(
                            fontSize: 9 + v * 0.5,
                            color: Brand.muted,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : Container(
                          width: 20,
                          height: (1.5 + math.min(v, 8.0) * 0.6).clamp(
                            2.0,
                            10.0,
                          ),
                          decoration: BoxDecoration(
                            color: Brand.muted,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                ),
              ),
          ],
        ),
        SizedBox(
          height: 30,
          child: Slider(
            value: t.clamp(0.0, 1.0),
            onChanged: (v) => tools.setWidth(range.min * math.exp(v * ratio)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([tools, palette]),
      builder: (context, _) {
        final mode = tools.mode;
        final kinds = switch (mode) {
          ToolMode.pen => _kinds<InkTool>(
            const [
              (InkTool.pen, 'حبر'),
              (InkTool.pencil, 'رصاص'),
              (InkTool.calligraphy, 'خط عربي'),
            ],
            tools.penKind,
            tools.setPenKind,
          ),
          ToolMode.eraser => _kinds<bool>(
            const [(true, 'ممحاة عادية'), (false, 'خط كامل')],
            tools.eraserPartial,
            tools.setEraserPartial,
          ),
          ToolMode.shape => _kinds<ShapeKind>(
            const [
              (ShapeKind.line, 'خط'),
              (ShapeKind.arrow, 'سهم'),
              (ShapeKind.rectangle, 'مستطيل'),
              (ShapeKind.ellipse, 'دائرة'),
              (ShapeKind.triangle, 'مثلث'),
            ],
            tools.shapeKind,
            tools.setShapeKind,
          ),
          ToolMode.word => _kinds<MarkStyle>(
            const [
              (MarkStyle.highlight, 'تظليل'),
              (MarkStyle.underline, 'تسطير'),
              (MarkStyle.strike, 'شطب'),
              (MarkStyle.textColor, 'لون الخط'),
              (MarkStyle.comment, 'تعليق'),
            ],
            tools.markStyle,
            tools.setMarkStyle,
          ),
          _ => null,
        };
        final snap = mode == ToolMode.pen || mode == ToolMode.highlighter;
        final colored = tools.hasStyle && mode != ToolMode.tape;
        return Glass(
          radius: 22,
          padding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (kinds != null)
                  Align(alignment: AlignmentDirectional.center, child: kinds),
                if (colored) ...[
                  if (kinds != null) const SizedBox(height: 10),
                  ColorChoices(
                    palette: palette,
                    selected: tools.color,
                    onPicked: (c) {
                      tools.setColor(c);
                      onColor();
                    },
                  ),
                ],
                if (tools.hasWidth) ...[
                  const SizedBox(height: 6),
                  _widths(context),
                ],
                if (snap) ...[
                  const SizedBox(height: 4),
                  _toggle(
                    'استقامة تلقائية عند التوقف',
                    tools.snapShapes,
                    tools.setSnapShapes,
                  ),
                ],
                if (mode == ToolMode.pen ||
                    mode == ToolMode.highlighter ||
                    mode == ToolMode.shape) ...[
                  const SizedBox(height: 4),
                  _toggle('الإصبع يرسم', fingerDraws, onFinger),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The tools kept in the box, with the button for arranging them.
class ToolBox extends StatelessWidget {
  const ToolBox({
    super.key,
    required this.layout,
    required this.tools,
    required this.isBook,
    required this.onTool,
    required this.onSettings,
  });

  final ToolLayout layout;
  final ToolController tools;
  final bool isBook;
  final void Function(ReaderTool) onTool;
  final VoidCallback onSettings;

  bool _active(ReaderTool t) {
    final m = t.mode;
    if (m != null) return tools.mode == m;
    return t == ReaderTool.ruler && tools.ruler.value != null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([layout, tools, tools.ruler]),
      builder: (context, _) {
        final items = [
          for (final t in layout.box)
            if (isBook || !t.forBooksOnly) t,
        ];
        return Glass(
          radius: 22,
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (items.isNotEmpty)
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 76.0 * math.min(3, items.length) + 12,
                    ),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final t in items)
                          GestureDetector(
                            onTap: () => onTool(t),
                            child: Container(
                              width: 76,
                              height: 70,
                              decoration: BoxDecoration(
                                color: _active(t)
                                    ? Brand.tint
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(t.icon, size: 23, color: Brand.blue),
                                  const SizedBox(height: 4),
                                  Text(
                                    t.label,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: _active(t)
                                          ? FontWeight.w700
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (items.isNotEmpty) const SizedBox(height: 8),
              GestureDetector(
                onTap: onSettings,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Brand.wash,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.settings_outlined,
                        size: 18,
                        color: Brand.blue,
                      ),
                      SizedBox(width: 7),
                      Text('إعدادات الأدوات', style: TextStyle(fontSize: 13.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Holds a panel under the bars (tool box, tool options, selection): never
/// wider than the screen nor taller than the room left under the bars, as
/// the device's own size says. What does not fit scrolls.
class PanelFrame extends StatelessWidget {
  const PanelFrame({super.key, required this.child, this.reserved = 150});

  final Widget child;

  /// Height taken by the bars above and the margins.
  final double reserved;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxH = math.max(
      120.0,
      mq.size.height - mq.padding.vertical - reserved,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: math.max(0, mq.size.width - 20),
        maxHeight: maxH,
      ),
      child: SingleChildScrollView(child: child),
    );
  }
}

/// Delete or copy what the lasso selected.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.selection,
    required this.onColor,
  });

  final SelectionController selection;
  final VoidCallback onColor;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 15,
      padding: const EdgeInsets.all(4),
      // On a narrow screen the buttons go on a second line.
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFB3322A),
              minimumSize: const Size(0, 38),
            ),
            onPressed: selection.deleteSelected,
            child: const Text('حذف المحدد'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Brand.ink,
              minimumSize: const Size(0, 38),
            ),
            onPressed: selection.duplicateSelected,
            child: const Text('تكرار المحدد'),
          ),
          if (selection.item?.kind != ItemKind.image &&
              selection.currentColor != null)
            GestureDetector(
              onTap: onColor,
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(selection.currentColor!),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [BoxShadow(color: Brand.line, spreadRadius: 1)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "41 / 520": the page being read; tapping it opens the pages.
class PagePill extends StatelessWidget {
  const PagePill({
    super.key,
    required this.page,
    required this.count,
    required this.onTap,
    this.extra = false,
  });

  final int page;
  final int count;
  final VoidCallback onTap;

  /// A page added after [page]: shown as "page +".
  final bool extra;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Glass(
        radius: 17,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: extra ? '$page +' : '$page',
                style: TextStyle(
                  color: Brand.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (count > 0)
                TextSpan(
                  text: ' / $count',
                  style: TextStyle(color: Brand.muted, fontSize: 13),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The strip at the top of a page added inside a book: a long press (or a
/// tap) on it offers to move the page or remove it.
class ExtraPageTab extends StatelessWidget {
  const ExtraPageTab({super.key, required this.after, required this.onActions});

  final int after;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onActions,
      onTap: onActions,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: Brand.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.blue.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.drag_indicator, size: 16, color: Brand.blue),
            const SizedBox(width: 4),
            Text(
              'صفحة مضافة بعد $after',
              style: TextStyle(fontSize: 12, color: Brand.blue),
            ),
          ],
        ),
      ),
    );
  }
}

/// The round "+" of a note: one more blank page after the last.
class AddPageButton extends StatelessWidget {
  const AddPageButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'صفحة جديدة',
      child: Material(
        color: Brand.blue,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const SizedBox(
            width: 46,
            height: 46,
            child: Icon(Icons.add, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

/// While the bars are away: a small round button showing the tool in use
/// brings them back.
class ToolDot extends StatelessWidget {
  const ToolDot({
    super.key,
    required this.icon,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final VoidCallback onTap;

  /// The colour of the tool in use, when it writes.
  final Color? color;

  /// The small tab at the top that brings the bars back: the tool in use
  /// and an arrow, as it always was.
  @override
  Widget build(BuildContext context) => Material(
    color: Brand.surface.withValues(alpha: 0.92),
    elevation: 2,
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color ?? Brand.blue),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, size: 18, color: Brand.muted),
          ],
        ),
      ),
    ),
  );
}
