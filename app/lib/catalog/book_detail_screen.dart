import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../library/library_store.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_cover.dart';
import 'catalog_models.dart';
import 'catalog_screen.dart' show formatSize, joinFacts;
import 'cover_image.dart';
import 'download_manager.dart';

/// All about one book: its cover and information, what it allows, and its
/// files. A book in parts offers each part, and all of them at once.
class BookDetailScreen extends StatelessWidget {
  const BookDetailScreen({
    super.key,
    required this.book,
    required this.downloads,
    required this.library,
    required this.onOpen,
  });

  final CatalogBook book;
  final DownloadManager downloads;
  final LibraryStore library;
  final void Function(BookEntry) onOpen;

  /// The features when every file has the same ones, else null.
  BookFeatures? get _common {
    if (book.parts.isEmpty) return null;
    final first = book.parts.first.features.labelled;
    for (final p in book.parts) {
      final l = p.features.labelled;
      for (var i = 0; i < l.length; i++) {
        if (l[i].$2 != first[i].$2) return null;
      }
    }
    return book.parts.first.features;
  }

  List<(String, String)> get _facts => [
    ('المؤلف', book.author),
    ('المحقق', book.investigator),
    ('الطبعة', book.edition),
    if (book.multiPart) ('عدد الأجزاء', '${book.partsCount}'),
    ('اللغة', book.language),
    ('التصنيف', book.subject),
    ('الناشر', book.publisher),
  ].where((f) => f.$2.isNotEmpty).toList();

  void _open(BuildContext context, BookEntry entry) {
    Navigator.of(context).pop();
    onOpen(entry);
  }

  Widget _header(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRect(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Color(0x7A0B2346),
                  BlendMode.srcATop,
                ),
                child: Transform.scale(
                  scale: 1.6,
                  child: CoverImage(
                    book.cover,
                    width: MediaQuery.sizeOf(context).width,
                    height: 420,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: ColoredBox(color: Brand.blueNight.withValues(alpha: 0.55)),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(18, top + 6, 18, 24 + 28),
          child: Column(
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: HeroButton(
                  icon: Icons.arrow_back,
                  tooltip: 'رجوع',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              const SizedBox(height: 4),
              BookCover(book.cover, width: 136),
              const SizedBox(height: 16),
              Text(
                book.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  height: 1.35,
                ),
              ),
              if (book.author.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    book.author,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFDCE7F5), fontSize: 14),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 28,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Brand.paper,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final common = _common;
    final missing = book.partsCount - book.parts.length;
    return Scaffold(
      backgroundColor: Brand.paper,
      body: ListenableBuilder(
        listenable: Listenable.merge([downloads, library]),
        builder: (context, _) {
          final waiting = book.parts
              .where((p) => library.installedCatalog(book.id, p.number) == null)
              .where((p) => downloads.taskOf(book.id, p.number) == null)
              .toList();
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              _header(context),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (book.multiPart || waiting.isNotEmpty)
                          _Cta(
                            enabled: waiting.isNotEmpty,
                            label: waiting.isEmpty
                                ? 'كل الأجزاء محمّلة أو قيد التحميل'
                                : book.multiPart
                                ? 'تحميل كل الأجزاء (${waiting.length})'
                                : 'تحميل',
                            onPressed: () => downloads.enqueueAll(book),
                          ),
                        if (missing > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'متوفر ${book.parts.length} من ${book.partsCount} أجزاء.',
                              style: TextStyle(color: Brand.muted),
                            ),
                          ),
                        SectionTitle(book.multiPart ? 'الأجزاء' : 'الكتاب'),
                        for (final p in book.parts)
                          _PartRow(
                            book: book,
                            part: p,
                            downloads: downloads,
                            installed: library.installedCatalog(book.id, p.number),
                            onOpen: (e) => _open(context, e),
                            showFeatures: common == null,
                          ),
                        if (common != null) ...[
                          const SectionTitle('ما يدعمه هذا الكتاب'),
                          FeatureTags(common),
                        ],
                        if (_facts.isNotEmpty) ...[
                          const SectionTitle('عن الكتاب'),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final f in _facts)
                                _Fact(label: f.$1, value: f.$2),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Cta extends StatelessWidget {
  const _Cta({
    required this.enabled,
    required this.label,
    required this.onPressed,
  });

  final bool enabled;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: enabled ? onPressed : null,
        child: Ink(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            gradient: enabled
                ? const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [Color(0xFF2460AE), Brand.blueDeep],
                  )
                : null,
            color: enabled ? null : Brand.line,
            boxShadow: enabled
                ? const [
                    BoxShadow(
                      color: Color(0x47123A70),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (enabled) ...[
                const Icon(Icons.download, color: Colors.white, size: 21),
                const SizedBox(width: 9),
              ],
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.white : Brand.muted,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final w = (MediaQuery.sizeOf(context).width.clamp(0, 640) - 46) / 2;
    return Container(
      width: w,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(color: Color(0x0F16233A), blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: Brand.muted)),
          Text(value, style: const TextStyle(fontSize: 14), maxLines: 2),
        ],
      ),
    );
  }
}

/// What a book allows, as small tags; what it does not allow is pale.
class FeatureTags extends StatelessWidget {
  const FeatureTags(this.features, {super.key});

  final BookFeatures features;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        for (final (name, has) in features.labelled)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: has ? Brand.tint : Colors.transparent,
              borderRadius: BorderRadius.circular(15),
              border: has ? null : Border.all(color: Brand.line),
            ),
            child: Text(
              name,
              style: TextStyle(
                fontSize: 12.5,
                color: has ? Brand.onTint : Brand.muted,
                decoration: has ? null : TextDecoration.lineThrough,
              ),
            ),
          ),
      ],
    );
  }
}

/// One file of the book: its number, size, progress and the button for its
/// state (download, stop, again, open).
class _PartRow extends StatelessWidget {
  const _PartRow({
    required this.book,
    required this.part,
    required this.downloads,
    required this.installed,
    required this.onOpen,
    required this.showFeatures,
  });

  final CatalogBook book;
  final CatalogPart part;
  final DownloadManager downloads;
  final BookEntry? installed;
  final void Function(BookEntry) onOpen;
  final bool showFeatures;

  String get _name => book.multiPart
      ? (part.label.isEmpty ? 'الجزء ${part.number}' : part.label)
      : 'الكتاب';

  String get _facts => joinFacts([
    part.formatName,
    if (part.pages > 0) '${part.pages} صفحة',
    formatSize(part.size),
  ]);

  Widget _action(DownloadTask? t) {
    final entry = installed;
    if (entry != null) {
      return _Mini('فتح', primary: true, onTap: () => onOpen(entry));
    }
    if (t == null) {
      return _Mini('تحميل', onTap: () => downloads.enqueue(book, part));
    }
    if (t.state == DownloadState.failed) {
      return _Mini('إعادة', onTap: () => downloads.enqueue(book, part));
    }
    if (t.state == DownloadState.waiting) {
      return _Mini('إيقاف', onTap: () => downloads.cancel(t));
    }
    return _Mini('إيقاف', onTap: () => downloads.cancel(t));
  }

  @override
  Widget build(BuildContext context) {
    final t = downloads.taskOf(book.id, part.number);
    final failed = t?.state == DownloadState.failed;
    final waiting = t?.state == DownloadState.waiting;
    final sub = t == null || failed
        ? _facts
        : waiting
        ? 'في الانتظار'
        : '${formatSize(t.received)} من ${formatSize(part.size)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(17),
        boxShadow: const [
          BoxShadow(color: Color(0x0F16233A), blurRadius: 18, offset: Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Brand.tint,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${part.number}',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: Brand.blue,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _name,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      sub,
                      style: TextStyle(fontSize: 12.5, color: Brand.muted),
                    ),
                  ],
                ),
              ),
              _action(t),
            ],
          ),
          if (t != null && !failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: waiting ? 0 : t.progress,
                  minHeight: 4,
                ),
              ),
            ),
          if (failed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                t!.error ?? 'تعذّر التحميل.',
                style: const TextStyle(color: Brand.red, fontSize: 13),
              ),
            ),
          if (showFeatures)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FeatureTags(part.features),
            ),
        ],
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini(this.label, {required this.onTap, this.primary = false});

  final String label;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: primary ? Brand.blue : Brand.tint,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: primary ? Colors.white : Brand.blue,
          ),
        ),
      ),
    ),
  );
}
