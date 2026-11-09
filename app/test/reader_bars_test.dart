import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/selection.dart';
import 'package:nots/ink/tool_controller.dart';
import 'package:nots/reader/reader_chrome.dart';
import 'package:nots/reader/tool_layout.dart';
import 'package:nots/ui/color_palette.dart';
import 'package:nots/ui/theme.dart';

/// Phone upright, phone on its side, tablet, and a very narrow phone.
const _screens = <String, Size>{
  'phone': Size(390, 844),
  'phone on its side': Size(844, 390),
  'tablet': Size(1180, 820),
  'narrow phone': Size(320, 640),
};

Future<void> _show(WidgetTester t, Size size, Widget child) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  for (final MapEntry(key: name, value: size) in _screens.entries) {
    for (final isBook in [true, false]) {
      final what = isBook ? 'book' : 'note';
      testWidgets('$name, $what: every tool in the bar stays on the screen', (
        t,
      ) async {
        // As many tools in the bar as there are: nothing may go off screen
        // (a Row that does not fit throws in tests).
        final layout = ToolLayout(bar: ReaderTool.values, box: const []);
        final doc = InkDocument();
        final tools = ToolController();
        await _show(
          t,
          size,
          ReaderBars(
            tools: tools,
            layout: layout,
            document: doc,
            selection: SelectionController(doc),
            isBook: isBook,
            bookmarked: false,
            onBack: () {},
            onMasdar: () {},
            onHistory: () {},
            onToc: () {},
            onSearch: () {},
            onBookmark: () {},
            onMore: () {},
            onTool: (_) {},
            onBox: () {},
            boxOpen: false,
          ),
        );
        expect(t.takeException(), isNull);
        // The whole row of tools is inside the screen's width.
        final bar = t.getRect(find.byType(ReaderBars));
        expect(bar.left, greaterThanOrEqualTo(0));
        expect(bar.right, lessThanOrEqualTo(size.width));
      });
    }

    testWidgets('$name: the tool box, with every tool, fits', (t) async {
      await _show(
        t,
        size,
        PanelFrame(
          child: ToolBox(
            layout: ToolLayout(bar: const [], box: ReaderTool.values),
            tools: ToolController(),
            isBook: true,
            onTool: (_) {},
            onSettings: () {},
          ),
        ),
      );
      expect(t.takeException(), isNull);
    });

    for (final mode in [
      ToolMode.pen,
      ToolMode.highlighter,
      ToolMode.eraser,
      ToolMode.shape,
      ToolMode.text,
    ]) {
      testWidgets('$name: the options of ${mode.name} fit', (t) async {
        await _show(
          t,
          size,
          PanelFrame(
            child: ToolOptions(
              tools: ToolController()..setMode(mode),
              palette: ColorPalette(),
              fingerDraws: true,
              onFinger: (_) {},
              onColor: () {},
            ),
          ),
        );
        expect(t.takeException(), isNull);
        final panel = t.getRect(find.byType(ToolOptions));
        expect(panel.left, greaterThanOrEqualTo(0));
        expect(panel.right, lessThanOrEqualTo(size.width));
      });
    }
  }
}
