import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// How far the reader may zoom out: until one whole page fits on the screen,
/// with a little room around it, and no further, so the screen never fills
/// with many small pages. [fitWidth] is the scale at which a page fills the
/// width, [fitPage] the one at which a whole page is visible (null when not
/// known yet).
double readerMinScale(double fitWidth, double? fitPage) =>
    math.min(fitWidth, fitPage ?? fitWidth) * ReaderZoom.room;

/// Zoom limits of the reader: in to 1600%, out to [readerMinScale]. Opens
/// at "fit width", like before.
class ReaderZoom extends PdfViewerSizeDelegateProvider {
  const ReaderZoom();

  /// Share of the whole-page scale the reader may still zoom out to.
  static const room = 0.85;
  static const maxScale = 16.0;

  @override
  PdfViewerSizeDelegate create() => _ReaderZoomDelegate(
    const PdfViewerSizeDelegateProviderLegacy(
      maxScale: maxScale,
      useAlternativeFitScaleAsMinScale: true,
    ).create(),
  );

  @override
  bool operator ==(Object other) => other is ReaderZoom;

  @override
  int get hashCode => (ReaderZoom).hashCode;
}

/// The standard sizing, with the lower zoom limit of [readerMinScale].
class _ReaderZoomDelegate implements PdfViewerSizeDelegate {
  _ReaderZoomDelegate(this._inner);

  final PdfViewerSizeDelegate _inner;

  @override
  void init(PdfViewerController controller) => _inner.init(controller);

  @override
  void dispose() => _inner.dispose();

  @override
  double get onePassRenderingScaleThreshold =>
      _inner.onePassRenderingScaleThreshold;

  @override
  PdfViewerLayoutMetrics calculateMetrics({
    required Size viewSize,
    required PdfPageLayout? layout,
    required int? pageNumber,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  }) {
    final m = _inner.calculateMetrics(
      viewSize: viewSize,
      layout: layout,
      pageNumber: pageNumber,
      pageMargin: pageMargin,
      boundaryMargin: boundaryMargin,
    );
    return PdfViewerLayoutMetrics(
      minScale: math.min(
        readerMinScale(m.coverScale, m.alternativeFitScale),
        m.maxScale,
      ),
      maxScale: m.maxScale,
      coverScale: m.coverScale,
      alternativeFitScale: m.alternativeFitScale,
    );
  }

  @override
  void onLayoutInitialized({
    required PdfViewerLayoutSnapshot state,
    required int initialPageNumber,
    required double coverScale,
    required double? alternativeFitScale,
    required PdfPageLayout layout,
    required PdfDocument document,
  }) => _inner.onLayoutInitialized(
    state: state,
    initialPageNumber: initialPageNumber,
    coverScale: coverScale,
    alternativeFitScale: alternativeFitScale,
    layout: layout,
    document: document,
  );

  @override
  void onLayoutUpdate({
    required PdfViewerLayoutSnapshot oldState,
    required PdfViewerLayoutSnapshot newState,
    required double currentZoom,
    required Rect oldVisibleRect,
    required int? anchorPageNumber,
    required bool isLayoutChanged,
    required bool isViewSizeChanged,
  }) => _inner.onLayoutUpdate(
    oldState: oldState,
    newState: newState,
    currentZoom: currentZoom,
    oldVisibleRect: oldVisibleRect,
    anchorPageNumber: anchorPageNumber,
    isLayoutChanged: isLayoutChanged,
    isViewSizeChanged: isViewSizeChanged,
  );
}

/// Pages one under the other as wide as the widest, with no margin at the
/// sides and a small gap between them, and room [top] above the first and
/// [bottom] below the last (in screen pixels) for the bars that float over
/// the page. [viewWidth] is the screen's width in pixels.
PdfPageLayoutFunction readerPageLayout({
  required double Function() top,
  required double bottom,
  required double Function() viewWidth,
}) => (pages, params) {
  final width = pages.fold<double>(0, (w, p) => math.max(w, p.width));
  // Screen pixels per page unit when the page fills the width.
  final scale = width > 0 ? viewWidth() / width : 1.0;
  final above = top() / scale;
  final below = bottom / scale;
  const gap = 6.0;
  var y = above;
  final rects = <Rect>[];
  for (final p in pages) {
    rects.add(Rect.fromLTWH((width - p.width) / 2, y, p.width, p.height));
    y += p.height + gap;
  }
  return PdfPageLayout(
    pageLayouts: rects,
    documentSize: Size(width, y - gap + below),
  );
};
