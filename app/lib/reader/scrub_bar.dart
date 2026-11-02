import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Page index for a drag at [y] on a track of [height] pixels holding
/// [pageCount] pages (1-based, clamped).
int pageForTrackY(double y, double height, int pageCount) {
  if (pageCount <= 1 || height <= 0) return 1;
  final t = (y / height).clamp(0.0, 1.0);
  return 1 + (t * (pageCount - 1)).round();
}

/// A handle on the side of the page that shows the current page. Dragging it
/// runs through the book: the pages move live behind it, and a thumbnail of
/// the page under the finger floats beside it, so the reader sees where the
/// pages are and carries on from there.
class ScrubBar extends StatefulWidget {
  const ScrubBar({super.key, required this.controller});

  final PdfViewerController controller;

  @override
  State<ScrubBar> createState() => _ScrubBarState();
}

class _ScrubBarState extends State<ScrubBar> {
  static const _thumbH = 34.0;
  static const _width = 52.0;

  bool _dragging = false;
  double _dragY = 0;
  int _page = 1;
  int _lastJumpMs = 0;
  final _track = GlobalKey();

  /// The handle shows while the pages move or a finger is on it, and slips
  /// away a moment later.
  bool _shown = false;
  Timer? _hideTimer;
  int _seenPage = 1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPageMoved);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPageMoved);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onPageMoved() {
    final c = widget.controller;
    if (!c.isReady) return;
    final page = c.pageNumber ?? 1;
    if (page != _seenPage) {
      _seenPage = page;
      _show();
    }
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_shown && mounted) setState(() => _shown = true);
    if (_dragging) return;
    _hideTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_dragging) setState(() => _shown = false);
    });
  }

  double _trackY(PointerEvent e) {
    final box = _track.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return _dragY;
    return box.globalToLocal(e.position).dy;
  }

  void _update(PointerEvent e, double height) {
    final c = widget.controller;
    if (!c.isReady) return;
    final y = (_trackY(e) - _thumbH / 2).clamp(0.0, height - _thumbH);
    final page = pageForTrackY(y, height - _thumbH, c.pageCount);
    setState(() {
      _dragY = y;
      _page = page;
    });
    // Run the book behind the finger, a few times a second.
    final now = e.timeStamp.inMilliseconds;
    if (now - _lastJumpMs >= 70 || page == 1 || page == c.pageCount) {
      _lastJumpMs = now;
      c.goToPage(pageNumber: page, duration: Duration.zero);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final height = box.maxHeight;
        return ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final c = widget.controller;
            if (!c.isReady || c.pageCount < 2) return const SizedBox.shrink();
            final count = c.pageCount;
            final current = (_dragging ? _page : (c.pageNumber ?? 1)).clamp(
              1,
              count,
            );
            final y = _dragging
                ? _dragY
                : (count <= 1
                      ? 0.0
                      : (current - 1) / (count - 1) * (height - _thumbH));
            return Stack(
              key: _track,
              clipBehavior: Clip.none,
              children: [
                if (_dragging)
                  Positioned(
                    left: _width + 4,
                    top: (y - 60).clamp(4.0, height - 190),
                    child: _Preview(
                      document: c.document,
                      page: current,
                      count: count,
                    ),
                  ),
                Positioned(
                  left: 0,
                  top: y,
                  // Hidden, only a thin strip at the edge is touchable.
                  width: _shown || _dragging ? _width : 22,
                  height: _thumbH,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) {
                      _hideTimer?.cancel();
                      setState(() {
                        _dragging = true;
                        _shown = true;
                      });
                      _update(e, height);
                    },
                    onPointerMove: (e) {
                      if (_dragging) _update(e, height);
                    },
                    onPointerUp: (_) {
                      setState(() => _dragging = false);
                      _show();
                    },
                    onPointerCancel: (_) {
                      setState(() => _dragging = false);
                      _show();
                    },
                    child: AnimatedOpacity(
                      opacity: _shown || _dragging ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(17),
                          ),
                          boxShadow: const [
                            BoxShadow(blurRadius: 3, color: Colors.black26),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$current',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.document,
    required this.page,
    required this.count,
  });

  final PdfDocument document;
  final int page;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 110,
              height: 150,
              child: PdfPageView(
                document: document,
                pageNumber: page,
                maximumDpi: 50,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$page / $count',
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ],
        ),
      ),
    );
  }
}
