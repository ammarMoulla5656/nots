import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../ink/ink_store.dart';
import '../ink/note_items.dart';
import '../ink/page_ink_overlay.dart';
import '../ink/selection.dart';
import '../ink/shapes.dart';
import '../ink/stroke.dart';
import '../ink/tool_controller.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.pdfPath});

  final String pdfPath;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _tools = ToolController();
  final _viewer = PdfViewerController();
  InkStore? _store;
  SelectionController? _selection;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _tools.addListener(_onToolChanged);
    InkStore.open(widget.pdfPath).then((s) {
      if (!mounted) {
        s.dispose();
        return;
      }
      setState(() {
        _store = s;
        _selection = SelectionController(s.document);
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  void _onToolChanged() {
    if (_tools.mode != ToolMode.lasso) _selection?.clear();
  }

  @override
  void dispose() {
    _tools.removeListener(_onToolChanged);
    _store?.dispose();
    _selection?.dispose();
    _tools.dispose();
    super.dispose();
  }

  List<Widget> _overlays(BuildContext context, Rect pageRect, PdfPage page) {
    final store = _store, selection = _selection;
    if (store == null || selection == null) return const [];
    return [
      PageInkOverlay(
        document: store.document,
        tools: _tools,
        selection: selection,
        pageNumber: page.pageNumber,
        pageWidthPt: page.width,
        pageWidthPx: pageRect.width,
        onCreateItem: _createItem,
        onEditItem: _editItem,
      ),
    ];
  }

  Future<void> _createItem(int page, ItemKind kind, Offset pt) async {
    final result = await _textDialog(
      title: kind == ItemKind.pin ? 'ملاحظة جديدة' : 'نص جديد',
    );
    final text = result?.text.trim() ?? '';
    if (result == null || result.delete || text.isEmpty) return;
    final doc = _store!.document;
    doc.addItem(
      page,
      NoteItem(
        id: doc.takeStrokeId(),
        kind: kind,
        x: pt.dx,
        y: pt.dy,
        w: kind == ItemKind.text ? NoteItem.defaultTextWidth : 0,
        text: text,
        color: kind == ItemKind.pin ? 0xFFEF6C00 : _tools.color,
        fontSize: _tools.textSize,
      ),
    );
  }

  Future<void> _editItem(int page, NoteItem item) async {
    final result = await _textDialog(
      title: item.kind == ItemKind.pin ? 'الملاحظة' : 'النص',
      initial: item.text,
      allowDelete: true,
    );
    if (result == null) return;
    final doc = _store!.document;
    final text = result.text.trim();
    if (result.delete || text.isEmpty) {
      doc.removeItem(page, item.id);
    } else if (text != item.text) {
      doc.replaceItem(page, item.copyWith(text: text));
    }
  }

  Future<({String text, bool delete})?> _textDialog({
    required String title,
    String initial = '',
    bool allowDelete = false,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<({String text, bool delete})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          if (allowDelete)
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, (text: initial, delete: true)),
              child: const Text('حذف'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  context, (text: controller.text, delete: false)),
              child: const Text('حفظ')),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _askPage() async {
    final controller = TextEditingController();
    final count = _viewer.pageCount;
    final n = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('الانتقال إلى صفحة (1 – $count)'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, int.tryParse(controller.text)),
              child: const Text('انتقال')),
        ],
      ),
    );
    controller.dispose();
    if (n != null && n >= 1 && n <= count) {
      await _viewer.goToPage(pageNumber: n);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.basenameWithoutExtension(widget.pdfPath),
            overflow: TextOverflow.ellipsis),
        actions: [
          ListenableBuilder(
            listenable: _viewer,
            builder: (context, _) {
              if (!_viewer.isReady) return const SizedBox.shrink();
              return TextButton(
                onPressed: _askPage,
                child: Text(
                    'صفحة ${_viewer.pageNumber ?? 1} / ${_viewer.pageCount}   ·   ${(_viewer.currentZoom * 100).round()}%'),
              );
            },
          ),
          ListenableBuilder(
            listenable: _tools,
            builder: (context, _) => IconButton(
              tooltip: _tools.fingerDraws
                  ? 'الإصبع يرسم (اضغط لرفض راحة اليد عند وجود قلم)'
                  : 'الإصبع لا يرسم عند وجود قلم',
              icon: Icon(_tools.fingerDraws
                  ? Icons.touch_app
                  : Icons.do_not_touch_outlined),
              onPressed: () => _tools.setFingerDraws(!_tools.fingerDraws),
            ),
          ),
          if (store != null)
            ListenableBuilder(
              listenable: store.document,
              builder: (context, _) => Row(children: [
                IconButton(
                  tooltip: 'تراجع',
                  icon: const Icon(Icons.undo),
                  onPressed: store.document.canUndo ? store.document.undo : null,
                ),
                IconButton(
                  tooltip: 'إعادة',
                  icon: const Icon(Icons.redo),
                  onPressed: store.document.canRedo ? store.document.redo : null,
                ),
              ]),
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('تعذّر فتح ملف الكتابة: $_error'))
          : store == null || _selection == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    Positioned.fill(
                      child: ListenableBuilder(
                        listenable: _tools,
                        builder: (context, _) => PdfViewer.file(
                          widget.pdfPath,
                          controller: _viewer,
                          params: PdfViewerParams(
                            // While drawing, one finger or the pen must not
                            // move the page, but pinching with two fingers
                            // still zooms. Use the hand tool to scroll.
                            panEnabled: !_tools.drawing,
                            // Allow zooming out below "fit width" (20%) and in
                            // to 1600%; vector ink stays sharp at any level.
                            sizeDelegateProvider:
                                const PdfViewerSizeDelegateProviderLegacy(
                              minScale: 0.2,
                              maxScale: 16,
                              useAlternativeFitScaleAsMinScale: false,
                            ),
                            pageOverlaysBuilder: _overlays,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16,
                      child: Center(
                        child: _Toolbar(
                          tools: _tools,
                          viewer: _viewer,
                          selection: _selection!,
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.tools,
    required this.viewer,
    required this.selection,
  });

  final ToolController tools;
  final PdfViewerController viewer;
  final SelectionController selection;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([tools, selection]),
      builder: (context, _) {
        final options = _options(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (options != null) ...[
              _bar(context, options),
              const SizedBox(height: 8),
            ],
            _bar(context, [
              _mode(context, ToolMode.hand, Icons.pan_tool_alt_outlined, 'تحريك'),
              _mode(context, ToolMode.pen, Icons.edit, 'قلم'),
              _mode(context, ToolMode.highlighter, Icons.border_color, 'تظليل'),
              _mode(context, ToolMode.shape, Icons.category_outlined, 'أشكال'),
              _mode(context, ToolMode.text, Icons.text_fields, 'نص'),
              _mode(context, ToolMode.pin, Icons.push_pin_outlined, 'ملاحظة'),
              _mode(context, ToolMode.tape, Icons.visibility_off_outlined, 'شريط لاصق للحفظ'),
              _mode(context, ToolMode.lasso, Icons.gesture, 'تحديد حر'),
              _mode(context, ToolMode.eraser, Icons.auto_fix_normal, 'ممحاة'),
              const SizedBox(height: 28, child: VerticalDivider()),
              IconButton(
                tooltip: 'تصغير',
                icon: const Icon(Icons.zoom_out),
                onPressed: () => viewer.zoomDown(),
              ),
              IconButton(
                tooltip: 'تكبير',
                icon: const Icon(Icons.zoom_in),
                onPressed: () => viewer.zoomUp(),
              ),
            ]),
          ],
        );
      },
    );
  }

  Widget _bar(BuildContext context, List<Widget> children) {
    return Material(
      elevation: 6,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.center,
          spacing: 2,
          children: children,
        ),
      ),
    );
  }

  /// Options of the current tool, or null when it has none.
  List<Widget>? _options(BuildContext context) {
    final mode = tools.mode;
    if (mode == ToolMode.lasso && selection.active) {
      return [
        IconButton(
          tooltip: 'حذف المحدد',
          icon: const Icon(Icons.delete_outline),
          onPressed: selection.deleteSelected,
        ),
        IconButton(
          tooltip: 'تكرار المحدد',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: selection.duplicateSelected,
        ),
        for (final c in ToolController.penColors)
          _swatch(context, c, () => selection.recolor(c), false),
      ];
    }
    if (!tools.hasStyle) return null;

    return [
      if (mode == ToolMode.pen) ...[
        for (final (kind, label) in [
          (InkTool.pen, 'حبر'),
          (InkTool.pencil, 'رصاص'),
          (InkTool.calligraphy, 'خط عربي'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: ChoiceChip(
              label: Text(label),
              selected: tools.penKind == kind,
              onSelected: (_) => tools.setPenKind(kind),
            ),
          ),
        const SizedBox(height: 28, child: VerticalDivider()),
      ],
      if (mode == ToolMode.shape) ...[
        for (final (kind, icon, label) in [
          (ShapeKind.line, Icons.horizontal_rule, 'خط'),
          (ShapeKind.arrow, Icons.arrow_right_alt, 'سهم'),
          (ShapeKind.rectangle, Icons.crop_square, 'مستطيل'),
          (ShapeKind.ellipse, Icons.circle_outlined, 'دائرة / قطع ناقص'),
          (ShapeKind.triangle, Icons.change_history, 'مثلث'),
        ])
          IconButton(
            tooltip: label,
            isSelected: tools.shapeKind == kind,
            icon: Icon(icon),
            style: IconButton.styleFrom(
              backgroundColor: tools.shapeKind == kind
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
            ),
            onPressed: () => tools.setShapeKind(kind),
          ),
        const SizedBox(height: 28, child: VerticalDivider()),
      ],
      for (final c in tools.palette)
        _swatch(context, c, () => tools.setColor(c), tools.color == c),
      IconButton(
        tooltip: 'لون مخصص',
        icon: const Icon(Icons.palette_outlined),
        onPressed: () async {
          final c = await showColorDialog(context, Color(tools.color));
          if (c != null) tools.addCustomColor(c.toARGB32());
        },
      ),
      if (tools.hasWidth) ...[
        const SizedBox(height: 28, child: VerticalDivider()),
        _widthControl(context),
      ],
      if (mode == ToolMode.pen || mode == ToolMode.highlighter) ...[
        const SizedBox(height: 28, child: VerticalDivider()),
        IconButton(
          tooltip: tools.snapShapes
              ? 'استقامة تلقائية عند التوقف: مفعّلة'
              : 'استقامة تلقائية عند التوقف: متوقفة',
          isSelected: tools.snapShapes,
          icon: const Icon(Icons.auto_fix_high),
          style: IconButton.styleFrom(
            backgroundColor: tools.snapShapes
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
          ),
          onPressed: () => tools.setSnapShapes(!tools.snapShapes),
        ),
      ],
    ];
  }

  Widget _mode(BuildContext context, ToolMode m, IconData icon, String tooltip) {
    final selected = tools.mode == m;
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor:
            selected ? Theme.of(context).colorScheme.primaryContainer : null,
      ),
      onPressed: () => tools.setMode(m),
    );
  }

  Widget _swatch(BuildContext context, int color, VoidCallback onTap, bool selected) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(5),
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  /// Continuous width (text size for the text tool) with a live preview dot.
  Widget _widthControl(BuildContext context) {
    final range = tools.widthRange;
    final w = tools.width.clamp(range.min, range.max);
    final dot = 6 + 18 * ((w - range.min) / (range.max - range.min));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 130,
          child: Slider(
            min: range.min,
            max: range.max,
            value: w,
            onChanged: tools.setWidth,
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: Color(tools.color),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Simple colour picker: hue, saturation and brightness sliders.
Future<Color?> showColorDialog(BuildContext context, Color initial) {
  var hsv = HSVColor.fromColor(initial);
  return showDialog<Color>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('لون مخصص'),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 48,
                decoration: BoxDecoration(
                  color: hsv.toColor(),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black26),
                ),
              ),
              Slider(
                value: hsv.hue,
                min: 0,
                max: 359.9,
                onChanged: (v) => setState(() => hsv = hsv.withHue(v)),
              ),
              Slider(
                value: hsv.saturation,
                onChanged: (v) => setState(() => hsv = hsv.withSaturation(v)),
              ),
              Slider(
                value: hsv.value,
                onChanged: (v) => setState(() => hsv = hsv.withValue(v)),
              ),
            ],
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
      ),
    ),
  );
}
