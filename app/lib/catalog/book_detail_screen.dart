import 'package:flutter/material.dart';

import '../library/library_store.dart';
import 'catalog_models.dart';
import 'catalog_screen.dart' show formatSize, joinFacts;
import 'cover_image.dart';
import 'download_manager.dart';

/// All about one book: its information, what it allows, and its files. A
/// book in parts offers each part, and all of them at once.
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

  Widget _head(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CoverImage(book.cover, width: 110, height: 154),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(book.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            for (final f in _facts)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${f.$1}: ',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      TextSpan(text: f.$2),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final common = _common;
    final missing = book.partsCount - book.parts.length;
    return Scaffold(
      appBar: AppBar(title: Text(book.title, maxLines: 1)),
      body: ListenableBuilder(
        listenable: Listenable.merge([downloads, library]),
        builder: (context, _) {
          final waiting = book.parts
              .where((p) => library.byCatalog(book.id, p.number) == null)
              .where((p) => downloads.taskOf(book.id, p.number) == null)
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _head(context),
              const SizedBox(height: 20),
              if (common != null) ...[
                Text(
                  'ما يدعمه هذا الكتاب',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                FeatureChips(common),
                const SizedBox(height: 20),
              ],
              if (book.multiPart) ...[
                FilledButton.icon(
                  onPressed: waiting.isEmpty
                      ? null
                      : () => downloads.enqueueAll(book),
                  icon: const Icon(Icons.download),
                  label: Text(
                    waiting.isEmpty
                        ? 'كل الأجزاء محمّلة أو قيد التحميل'
                        : 'تحميل كل الأجزاء (${waiting.length})',
                  ),
                ),
                const SizedBox(height: 12),
                if (missing > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'متوفر ${book.parts.length} من ${book.partsCount} أجزاء.',
                    ),
                  ),
              ],
              for (final p in book.parts)
                _PartTile(
                  book: book,
                  part: p,
                  downloads: downloads,
                  installed: library.byCatalog(book.id, p.number),
                  showFeatures: common == null,
                  onOpen: (e) => _open(context, e),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// What a book allows, with what it does not shown as such.
class FeatureChips extends StatelessWidget {
  const FeatureChips(this.features, {super.key});

  final BookFeatures features;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (name, has) in features.labelled)
          Chip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(
              has ? Icons.check : Icons.close,
              size: 16,
              color: has ? scheme.primary : scheme.outline,
            ),
            label: Text(
              name,
              style: has ? null : TextStyle(color: scheme.outline),
            ),
          ),
      ],
    );
  }
}

class _PartTile extends StatelessWidget {
  const _PartTile({
    required this.book,
    required this.part,
    required this.downloads,
    required this.installed,
    required this.showFeatures,
    required this.onOpen,
  });

  final CatalogBook book;
  final CatalogPart part;
  final DownloadManager downloads;
  final BookEntry? installed;
  final bool showFeatures;
  final void Function(BookEntry) onOpen;

  String get _name =>
      book.multiPart
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
      return FilledButton.tonal(
        onPressed: () => onOpen(entry),
        child: const Text('فتح'),
      );
    }
    if (t == null) {
      return FilledButton.tonalIcon(
        onPressed: () => downloads.enqueue(book, part),
        icon: const Icon(Icons.download, size: 18),
        label: const Text('تحميل'),
      );
    }
    if (t.state == DownloadState.failed) {
      return FilledButton.tonal(
        onPressed: () => downloads.enqueue(book, part),
        child: const Text('إعادة'),
      );
    }
    return IconButton(
      tooltip: 'إيقاف',
      onPressed: () => downloads.cancel(t),
      icon: const Icon(Icons.close),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = downloads.taskOf(book.id, part.number);
    final failed = t?.state == DownloadState.failed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_name, style: Theme.of(context).textTheme.titleSmall),
                      Text(_facts, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                _action(t),
              ],
            ),
            if (t != null && !failed) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: t.state == DownloadState.waiting ? 0 : t.progress,
              ),
              const SizedBox(height: 4),
              Text(
                t.state == DownloadState.waiting
                    ? 'في الانتظار'
                    : '${formatSize(t.received)} من ${formatSize(part.size)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            if (failed) ...[
              const SizedBox(height: 6),
              Text(
                t!.error ?? 'تعذّر التحميل.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (showFeatures) ...[
              const SizedBox(height: 8),
              FeatureChips(part.features),
            ],
          ],
        ),
      ),
    );
  }
}
