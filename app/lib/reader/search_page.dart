import 'dart:async';

import 'package:flutter/material.dart';

import '../book/book_text.dart';

/// What the user picked from the search results.
typedef SearchPick = ({String query, List<SearchHit> hits, int index});

/// Full-screen search in the linked book text. Results update while typing;
/// picking one returns it so the reader can open that PDF page.
class BookSearchPage extends StatefulWidget {
  const BookSearchPage({super.key, required this.book, this.initialQuery = ''});

  final BookText book;
  final String initialQuery;

  @override
  State<BookSearchPage> createState() => _BookSearchPageState();
}

class _BookSearchPageState extends State<BookSearchPage> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  Timer? _debounce;
  List<SearchHit> _hits = const [];
  int _ms = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _run() {
    final sw = Stopwatch()..start();
    final hits = widget.book.search(_query.text);
    sw.stop();
    setState(() {
      _hits = hits;
      _ms = sw.elapsedMilliseconds;
    });
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _run);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = widget.book;
    final q = _query.text.trim();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'ابحث في نص الكتاب',
            border: InputBorder.none,
          ),
          onChanged: _changed,
          onSubmitted: (_) => _run(),
        ),
        actions: [
          if (q.isNotEmpty)
            IconButton(
              tooltip: 'مسح',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _query.clear();
                _run();
              },
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (q.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                _hits.isEmpty
                    ? 'لا نتائج'
                    : '${_hits.length} نتيجة في ${_ms < 1 ? 'أقل من 1' : _ms} ms',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: ListView.separated(
              itemCount: _hits.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final h = _hits[i];
                final s = book.snippet(h);
                final section = book.sectionOf(h.page)?.title;
                return ListTile(
                  title: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: s.before),
                        TextSpan(
                          text: s.match,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            backgroundColor: Colors.yellow.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                        TextSpan(text: s.after),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    'صفحة ${book.pdfPageOf(h.page)}${section == null ? '' : ' · $section'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop<SearchPick>(context, (
                    query: _query.text,
                    hits: _hits,
                    index: i,
                  )),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
