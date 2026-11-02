import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Grid of page thumbnails. Pages with writing or a bookmark are marked;
/// the filter shows only bookmarked or annotated pages. Returns the chosen
/// page number.
class PagesSheet extends StatefulWidget {
  const PagesSheet({
    super.key,
    required this.document,
    required this.pageCount,
    required this.currentPage,
    required this.bookmarks,
    required this.annotated,
  });

  final PdfDocument document;
  final int pageCount;
  final int currentPage;
  final Set<int> bookmarks;
  final Set<int> annotated;

  @override
  State<PagesSheet> createState() => _PagesSheetState();
}

enum _Filter { all, bookmarks, annotated }

class _PagesSheetState extends State<PagesSheet> {
  var _filter = _Filter.all;
  late final ScrollController _scroll;

  static const _cell = 150.0; // thumbnail height incl. label

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(initialScrollOffset: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  void _scrollToCurrent() {
    if (!_scroll.hasClients || _filter != _Filter.all) return;
    final width = _scroll.position.viewportDimension;
    final columns = (MediaQuery.sizeOf(context).width / 120).floor().clamp(
      2,
      10,
    );
    final row = (widget.currentPage - 1) ~/ columns;
    _scroll.jumpTo(
      (row * _cell - width / 3).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<int> get _pages => switch (_filter) {
    _Filter.all => [for (var i = 1; i <= widget.pageCount; i++) i],
    _Filter.bookmarks => widget.bookmarks.toList()..sort(),
    _Filter.annotated => widget.annotated.toList()..sort(),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pages = _pages;
    final columns = (MediaQuery.sizeOf(context).width / 120).floor().clamp(
      2,
      10,
    );
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<_Filter>(
              segments: [
                const ButtonSegment(
                  value: _Filter.all,
                  label: Text('كل الصفحات'),
                ),
                ButtonSegment(
                  value: _Filter.bookmarks,
                  label: Text('العلامات (${widget.bookmarks.length})'),
                ),
                ButtonSegment(
                  value: _Filter.annotated,
                  label: Text('المكتوب عليها (${widget.annotated.length})'),
                ),
              ],
              selected: {_filter},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
          Expanded(
            child: pages.isEmpty
                ? Center(
                    child: Text(
                      _filter == _Filter.bookmarks
                          ? 'لا توجد علامات بعد. أضفها من قائمة «المزيد».'
                          : 'لا توجد صفحات مكتوب عليها بعد.',
                    ),
                  )
                : GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: _cell,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: pages.length,
                    itemBuilder: (context, i) {
                      final n = pages[i];
                      final current = n == widget.currentPage;
                      return InkWell(
                        onTap: () => Navigator.pop(context, n),
                        child: Column(
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: current
                                        ? theme.colorScheme.primary
                                        : Colors.black12,
                                    width: current ? 3 : 1,
                                  ),
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    PdfPageView(
                                      document: widget.document,
                                      pageNumber: n,
                                      maximumDpi: 40,
                                    ),
                                    if (widget.bookmarks.contains(n))
                                      const Positioned(
                                        top: 0,
                                        right: 4,
                                        child: Icon(
                                          Icons.bookmark,
                                          color: Colors.red,
                                          size: 22,
                                        ),
                                      ),
                                    if (widget.annotated.contains(n))
                                      const Positioned(
                                        bottom: 2,
                                        left: 2,
                                        child: Icon(
                                          Icons.edit,
                                          color: Colors.blue,
                                          size: 16,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text('$n', style: theme.textTheme.bodySmall),
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
