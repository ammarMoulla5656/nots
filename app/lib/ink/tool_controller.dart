import 'package:flutter/foundation.dart';

import 'shapes.dart';
import 'stroke.dart';

enum ToolMode {
  hand,
  pen,
  highlighter,
  eraser,
  lasso,
  shape,
  text,
  pin,
  tape,
}

/// Current tool, colours and sizes. Widths are in PDF points.
class ToolController extends ChangeNotifier {
  ToolMode _mode = ToolMode.hand;
  InkTool _penKind = InkTool.pen;
  ShapeKind _shapeKind = ShapeKind.line;
  int _penColor = 0xFF1A1A1A;
  int _highlighterColor = 0xFFFFEB3B;
  double _penWidth = 1.6;
  double _highlighterWidth = 14;
  double _textSize = 14;
  bool _fingerDraws = true;
  bool _snapShapes = true;

  ToolMode get mode => _mode;
  bool get drawing => _mode != ToolMode.hand;

  /// Pen family used by the pen tool: ink, pencil or calligraphy.
  InkTool get penKind => _penKind;

  /// Shape drawn by the shape tool.
  ShapeKind get shapeKind => _shapeKind;

  /// The kind of stroke the current tool produces.
  InkTool get strokeTool =>
      _mode == ToolMode.highlighter ? InkTool.highlighter : _penKind;

  /// When false and a stylus has been seen, finger touches are ignored
  /// (palm rejection).
  bool get fingerDraws => _fingerDraws;

  /// Hold still at the end of a stroke to turn it into a clean line,
  /// ellipse or rectangle.
  bool get snapShapes => _snapShapes;

  int get color =>
      _mode == ToolMode.highlighter ? _highlighterColor : _penColor;

  /// Width of strokes; text size in text mode.
  double get width => switch (_mode) {
        ToolMode.highlighter => _highlighterWidth,
        ToolMode.text => _textSize,
        _ => _penWidth,
      };

  double get textSize => _textSize;

  /// Continuous width ranges in PDF points.
  static const penWidthRange = (min: 0.3, max: 8.0);
  static const highlighterWidthRange = (min: 4.0, max: 40.0);
  static const textSizeRange = (min: 8.0, max: 48.0);

  ({double min, double max}) get widthRange => switch (_mode) {
        ToolMode.highlighter => highlighterWidthRange,
        ToolMode.text => textSizeRange,
        _ => penWidthRange,
      };

  /// Whether the width slider and palette apply to the current tool.
  bool get hasStyle =>
      _mode != ToolMode.hand &&
      _mode != ToolMode.eraser &&
      _mode != ToolMode.lasso;

  /// Whether the width slider applies (pins and tape have no size).
  bool get hasWidth =>
      _mode == ToolMode.pen ||
      _mode == ToolMode.highlighter ||
      _mode == ToolMode.shape ||
      _mode == ToolMode.text;

  final List<int> _customPen = [];
  final List<int> _customHighlighter = [];

  /// Remembers a colour chosen with the colour dialog (last 5 per tool).
  void addCustomColor(int c) {
    final list =
        _mode == ToolMode.highlighter ? _customHighlighter : _customPen;
    list.remove(c);
    list.add(c);
    if (list.length > 5) list.removeAt(0);
    setColor(c);
  }

  static const penColors = [
    0xFF1A1A1A,
    0xFFD32F2F,
    0xFF1565C0,
    0xFF2E7D32,
    0xFFEF6C00,
  ];
  static const highlighterColors = [
    0xFFFFEB3B,
    0xFF76FF03,
    0xFFFF80AB,
    0xFF40C4FF,
  ];

  List<int> get palette => _mode == ToolMode.highlighter
      ? [...highlighterColors, ..._customHighlighter]
      : [...penColors, ..._customPen];

  void setMode(ToolMode m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
  }

  void setPenKind(InkTool kind) {
    assert(kind != InkTool.highlighter);
    _penKind = kind;
    notifyListeners();
  }

  void setShapeKind(ShapeKind kind) {
    _shapeKind = kind;
    notifyListeners();
  }

  void setColor(int c) {
    if (_mode == ToolMode.highlighter) {
      _highlighterColor = c;
    } else {
      _penColor = c;
    }
    notifyListeners();
  }

  void setWidth(double w) {
    switch (_mode) {
      case ToolMode.highlighter:
        _highlighterWidth = w;
      case ToolMode.text:
        _textSize = w;
      default:
        _penWidth = w;
    }
    notifyListeners();
  }

  void setFingerDraws(bool v) {
    _fingerDraws = v;
    notifyListeners();
  }

  void setSnapShapes(bool v) {
    _snapShapes = v;
    notifyListeners();
  }
}
