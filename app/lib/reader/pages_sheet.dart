import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../ui/brand_widgets.dart';
import '../ui/theme.dart';

/// Which pages the sheet lists.
enum PagesMode { all, bookmarks, annotated }

/// Grid of page thumbnails: every page (with a box to go to one by number),
/// or only the bookmarked pages, or only the pages written on. Returns the
/// chosen page number.
class PagesSheet extends StatefulWidget {
  const PagesSheet({
    super.key,
    required this.document,
    required this.pageCount,
    required this.currentPage,
    required this.bookmarks,
    required this.annotated,
    this.mode = PagesMode.all,
  });

  final PdfDocument document;
  final int pageCount;
  final int currentPage;
  final Set<int> bookmarks;
  final Set<int> annotated;
  final PagesMode mode;

  @override
  State<PagesSheet> createState() => _PagesSheetState();
}

class _PagesSheetState extends State<PagesSheet> {
  late final ScrollController _scroll;
  final _goto = TextEditingController();

  /// The pages one under the other, each as wide as fits (up to 340).
  double _pageWidth(BuildContext context) =>
      math.min(_sheetWidth(context) - 32, 340);

  double _cellOf(BuildContext context) => _pageWidth(context) * 1.42 + 24;

  int _columns(BuildContext context) => 1;

  /// The sheet is at most 600 wide (on a tablet).
  double _sheetWidth(BuildContext context) =>
      math.min(MediaQuery.sizeOf(context).width, 600);

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  void _scrollToCurrent() {
    if (!_scroll.hasClients || widget.mode != PagesMode.all) return;
    final width = _scroll.position.viewportDimension;
    final row = (widget.currentPage - 1) ~/ _columns(context);
    final cell = _cellOf(context) + 12;
    _scroll.jumpTo(
      (row * cell - width / 6).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    _goto.dispose();
    super.dispose();
  }

  List<int> get _pages => switch (widget.mode) {
    PagesMode.all => [for (var i = 1; i <= widget.pageCount; i++) i],
    PagesMode.bookmarks => widget.bookmarks.toList()..sort(),
    PagesMode.annotated => widget.annotated.toList()..sort(),
  };

  String get _title => switch (widget.mode) {
    PagesMode.all => 'الصفحات',
    PagesMode.bookmarks => 'العلامات',
    PagesMode.annotated => 'المكتوب عليها',
  };

  void _go() {
    final n = int.tryParse(_goto.text.trim());
    if (n != null && n >= 1 && n <= widget.pageCount) {
      Navigator.pop(context, n);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    return SafeArea(
      child: Column(
        children: [
          SheetHeader(_title),
          if (widget.mode == PagesMode.all)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: TextField(
                        controller: _goto,
                        keyboardType: TextInputType.number,
                        onSubmitted: (_) => _go(),
                        decoration: InputDecoration(
                          hintText: 'الانتقال إلى صفحة (1 – ${widget.pageCount})',
                          hintStyle: TextStyle(
                            color: Brand.muted,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(72, 44)),
                    onPressed: _go,
                    child: const Text('انتقال'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: pages.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Text(
                        widget.mode == PagesMode.bookmarks
                            ? 'لا توجد علامات بعد. ضع علامة على الصفحة من زر العلامة في الأعلى.'
                            : 'لا توجد صفحات مكتوب عليها بعد.',
                        style: TextStyle(color: Brand.muted, height: 1.7),
                      ),
                    ),
                  )
                : GridView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.symmetric(
                      horizontal:
                          (_sheetWidth(context) -
                              _pageWidth(context)) /
                          2,
                      vertical: 8,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _columns(context),
                      mainAxisExtent: _cellOf(context),
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: pages.length,
                    itemBuilder: (context, i) {
                      final n = pages[i];
                      final current = n == widget.currentPage;
                      return InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => Navigator.pop(context, n),
                        child: Column(
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: current ? Brand.blue : Brand.line,
                                    width: current ? 2.5 : 1,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    PdfPageView(
                                      document: widget.document,
                                      pageNumber: n,
                                      maximumDpi: 60,
                                    ),
                                    if (widget.bookmarks.contains(n))
                                      const Positioned(
                                        top: 0,
                                        right: 4,
                                        child: Icon(
                                          Icons.bookmark,
                                          color: Brand.gold,
                                          size: 22,
                                        ),
                                      ),
                                    if (widget.annotated.contains(n))
                                      Positioned(
                                        bottom: 3,
                                        left: 3,
                                        child: Icon(
                                          Icons.edit,
                                          color: Brand.blue,
                                          size: 16,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '$n',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Brand.muted,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
