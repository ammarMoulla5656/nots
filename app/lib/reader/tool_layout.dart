import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ink/tool_controller.dart';

/// Every tool the reader offers. Where each one sits (in the bar, or in the
/// box behind its button) is the user's to arrange: [ToolLayout].
enum ReaderTool {
  hand('hand', 'تحريك', Icons.pan_tool_alt_outlined, ToolMode.hand),
  pen('pen', 'قلم', Icons.edit_outlined, ToolMode.pen),
  highlighter('hl', 'تظليل', Icons.border_color_outlined, ToolMode.highlighter),
  eraser('eraser', 'ممحاة', Icons.auto_fix_normal, ToolMode.eraser),
  lasso('lasso', 'تحديد', Icons.gesture, ToolMode.lasso),
  laser('laser', 'ليزر', Icons.flare, ToolMode.laser),
  shape('shape', 'أشكال', Icons.category_outlined, ToolMode.shape),
  text('text', 'نص', Icons.text_fields, ToolMode.text),
  pin('pin', 'ملاحظة', Icons.push_pin_outlined, ToolMode.pin),
  tape('tape', 'شريط', Icons.visibility_off_outlined, ToolMode.tape),
  word('word', 'الكلمات', Icons.text_format, ToolMode.word),

  /// Not a mode: shows or hides the ruler over the page.
  ruler('ruler', 'المسطرة', Icons.straighten, null),

  /// Not a mode: asks for a picture and places it on the page.
  image('image', 'صورة', Icons.image_outlined, null);

  const ReaderTool(this.id, this.label, this.icon, this.mode);

  /// Stored in the settings file.
  final String id;
  final String label;
  final IconData icon;

  /// The mode of the tool controller this tool switches on, or null.
  final ToolMode? mode;

  static ReaderTool? byId(String id) {
    for (final t in values) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Tools that show their own options (kinds, colours, sizes) when chosen.
  bool get hasOptions => switch (this) {
    pen ||
    highlighter ||
    eraser ||
    shape ||
    text ||
    pin ||
    word ||
    laser => true,
    _ => false,
  };

  /// Only a book's words can be marked: a note has none.
  bool get forBooksOnly => this == word;

  /// The words tool is no longer offered: the highlighter marks words too.
  bool get offered => this != word;
}

/// Which tools are in the bar and which in the box, in order. Kept across
/// runs. Every tool is always in one of the two.
class ToolLayout extends ChangeNotifier {
  ToolLayout({List<ReaderTool>? bar, List<ReaderTool>? box})
    : _bar = List.of(bar ?? defaultBar),
      _box = List.of(box ?? defaultBox);

  /// The one shared by the reader.
  static final instance = ToolLayout();

  static const defaultBar = [
    ReaderTool.hand,
    ReaderTool.pen,
    ReaderTool.highlighter,
    ReaderTool.eraser,
    ReaderTool.lasso,
  ];
  static const defaultBox = [
    ReaderTool.laser,
    ReaderTool.shape,
    ReaderTool.text,
    ReaderTool.pin,
    ReaderTool.tape,
    ReaderTool.ruler,
    ReaderTool.image,
  ];

  List<ReaderTool> _bar;
  List<ReaderTool> _box;
  File? _file;

  List<ReaderTool> get bar => List.unmodifiable(_bar);
  List<ReaderTool> get box => List.unmodifiable(_box);

  bool inBar(ReaderTool t) => _bar.contains(t);

  /// Where the layout is kept; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'prefs'));

  Future<void> load() async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    final f = _file = File(p.join(dir.path, 'tools.json'));
    if (!await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      List<ReaderTool> read(Object? l) => [
        for (final id in (l as List? ?? const []).cast<String>())
          ?ReaderTool.byId(id),
      ];
      final bar = read(j['bar']), box = read(j['box']);
      // A tool missing from the file (added by a later version) goes to the
      // box; one named twice stays where it was first named.
      final seen = <ReaderTool>{};
      _bar = [
        for (final t in bar)
          if (seen.add(t)) t,
      ];
      _box = [
        for (final t in box)
          if (seen.add(t)) t,
      ];
      for (final t in ReaderTool.values) {
        if (t.offered && seen.add(t)) _box.add(t);
      }
      _bar.removeWhere((t) => !t.offered);
      _box.removeWhere((t) => !t.offered);
      notifyListeners();
    } on Object {
      // A damaged file brings back the usual arrangement.
    }
  }

  /// Puts [t] in the bar or the box, before position [index] (at the end
  /// when null), taking it out of where it was.
  void place(ReaderTool t, {required bool bar, int? index}) {
    _bar.remove(t);
    _box.remove(t);
    final list = bar ? _bar : _box;
    list.insert((index ?? list.length).clamp(0, list.length), t);
    _changed();
  }

  /// Moves [t] to the other place.
  void flip(ReaderTool t) => place(t, bar: !inBar(t));

  void reset() {
    _bar = List.of(defaultBar);
    _box = List.of(defaultBox);
    _changed();
  }

  void _changed() {
    notifyListeners();
    _file?.writeAsString(
      jsonEncode({
        'bar': [for (final t in _bar) t.id],
        'box': [for (final t in _box) t.id],
      }),
    );
  }
}
