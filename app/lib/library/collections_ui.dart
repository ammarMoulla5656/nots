import 'package:flutter/material.dart';

import '../catalog/book_cover.dart';
import '../notes/paper.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_widgets.dart';
import 'collections.dart';
import 'library_store.dart';
import 'notes_tab.dart' show NoteGridItem;

/// A small cover or sheet of paper for [b], whatever it is.
Widget collectionThumb(BookEntry b, double width) => b.isNote
    ? SizedBox(width: width, child: PaperPreview(PaperStyle.parse(b.author)))
    : BookCover(b.cover, ownId: b.id, width: width);

/// Asks for a name; null when the user changed their mind.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final c = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('تراجع'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, c.text.trim()),
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  c.dispose();
  return name == null || name.isEmpty ? null : name;
}

/// The first thing in «كتبي»: the collections side by side, to slide
/// through, and a card to make a new one.
class CollectionsStrip extends StatelessWidget {
  const CollectionsStrip({
    super.key,
    required this.library,
    required this.onOpen,
  });

  final LibraryStore library;
  final void Function(BookEntry) onOpen;

  Future<void> _new(BuildContext context) async {
    final name = await askName(context, title: 'اسم التجميعة');
    if (name == null || !context.mounted) return;
    final c = Collections.instance.create(name);
    await CollectionScreen.open(
      context,
      id: c.id,
      library: library,
      onOpen: onOpen,
    );
  }

  Widget _card(BuildContext context, Collection c) {
    final items = [for (final id in c.items) ?library.byId(id)];
    return GestureDetector(
      onTap: () => CollectionScreen.open(
        context,
        id: c.id,
        library: library,
        onOpen: onOpen,
      ),
      child: SizedBox(
        width: 112,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Up to three covers, one over another.
            SizedBox(
              height: 92,
              child: Stack(
                children: [
                  if (items.isEmpty)
                    Container(
                      width: 112,
                      decoration: BoxDecoration(
                        color: Brand.tint,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.folder_open_outlined,
                        color: Brand.onTint,
                        size: 34,
                      ),
                    )
                  else
                    for (var i = items.take(3).length - 1; i >= 0; i--)
                      PositionedDirectional(
                        start: i * 22.0,
                        top: i * 3.0,
                        child: ClipRect(
                          child: SizedBox(
                            height: 86,
                            child: collectionThumb(items[i], 58),
                          ),
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '${items.length} ${items.length == 1 ? 'عنصر' : 'عناصر'}',
              style: TextStyle(fontSize: 12, color: Brand.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _newCard(BuildContext context) => GestureDetector(
    onTap: () => _new(context),
    child: SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 92,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Brand.line, width: 1.5),
            ),
            child: Icon(Icons.add, color: Brand.blue, size: 30),
          ),
          const SizedBox(height: 7),
          const Text(
            'تجميعة جديدة',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Collections.instance, library]),
      builder: (context, _) {
        final all = Collections.instance.all;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('تجميعاتي', top: 6),
            SizedBox(
              height: 140,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final c in all) ...[
                    _card(context, c),
                    const SizedBox(width: 14),
                  ],
                  _newCard(context),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        );
      },
    );
  }
}

/// One collection: its books and notes, a button to add more, and the
/// menu to rename or remove it (the books themselves stay).
class CollectionScreen extends StatelessWidget {
  const CollectionScreen({
    super.key,
    required this.id,
    required this.library,
    required this.onOpen,
  });

  final String id;
  final LibraryStore library;
  final void Function(BookEntry) onOpen;

  static Future<void> open(
    BuildContext context, {
    required String id,
    required LibraryStore library,
    required void Function(BookEntry) onOpen,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          CollectionScreen(id: id, library: library, onOpen: onOpen),
    ),
  );

  Future<void> _remove(BuildContext context, Collection c, BookEntry b) async {
    final ok = await showNotsSheet<bool>(
      context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(b.title),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('إزالة من هذه التجميعة'),
                subtitle: const Text('يبقى في مكتبتك'),
                onTap: () => Navigator.pop(context, true),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok == true) Collections.instance.take(c, b.id);
  }

  @override
  Widget build(BuildContext context) {
    final side = sidePadding(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Collections.instance, library]),
      builder: (context, _) {
        final c = Collections.instance.byId(id);
        if (c == null) {
          return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
        }
        final items = [for (final i in c.items) ?library.byId(i)];
        return Scaffold(
          backgroundColor: Brand.paper,
          appBar: AppBar(
            title: Text(c.name),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final n = await askName(
                      context,
                      title: 'اسم التجميعة',
                      initial: c.name,
                    );
                    if (n != null) Collections.instance.rename(c, n);
                  } else if (v == 'delete') {
                    Collections.instance.remove(c);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('إعادة التسمية')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('حذف التجميعة (الكتب تبقى)'),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showAddToCollection(context, c, library),
            icon: const Icon(Icons.add),
            label: const Text('إضافة كتب أو ملاحظات'),
          ),
          body: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'التجميعة فارغة.\n\nاضغط «إضافة» لتضع فيها كتباً وملاحظات، أو اضغط مطولاً على أي كتاب واختر «إضافة إلى تجميعة».',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Brand.muted, height: 1.7),
                    ),
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(side, 12, side, 100),
                      sliver: CoverGridSliver(
                        count: items.length,
                        itemBuilder: (context, i) {
                          final b = items[i];
                          return b.isNote
                              ? NoteGridItem(
                                  note: b,
                                  onTap: () => onOpen(b),
                                  onMore: () => _remove(context, c, b),
                                )
                              : BookGridItem(
                                  book: b,
                                  subtitle: b.author,
                                  inAccountOnly: !library.isOnDevice(b),
                                  onTap: () => onOpen(b),
                                  onMore: () => _remove(context, c, b),
                                );
                        },
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// A sheet of every book and note, to tick the ones in [c].
Future<void> showAddToCollection(
  BuildContext context,
  Collection c,
  LibraryStore library,
) => showNotsSheet<void>(
  context,
  tall: true,
  builder: (context) => ListenableBuilder(
    listenable: Collections.instance,
    builder: (context, _) {
      final all = library.books..sort((a, b) => a.title.compareTo(b.title));
      return SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader('إضافة إلى «${c.name}»'),
            Expanded(
              child: ListView.builder(
                itemCount: all.length,
                itemBuilder: (context, i) {
                  final b = all[i];
                  final on = c.items.contains(b.id);
                  return ListTile(
                    leading: SizedBox(width: 38, child: collectionThumb(b, 38)),
                    title: Text(
                      b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      b.isNote ? 'ملاحظة' : b.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Icon(
                      on ? Icons.check_circle : Icons.circle_outlined,
                      color: on ? Brand.blue : Brand.line,
                    ),
                    onTap: () => on
                        ? Collections.instance.take(c, b.id)
                        : Collections.instance.add(c, b.id),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  ),
);

/// The sheet of «إضافة إلى تجميعة» for one book or note: the collections
/// with a tick on the ones it is in, and a new one.
Future<void> showCollectionPicker(
  BuildContext context,
  BookEntry b,
) => showNotsSheet<void>(
  context,
  builder: (context) => ListenableBuilder(
    listenable: Collections.instance,
    builder: (context, _) {
      final all = Collections.instance.all;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader('إضافة «${b.title}» إلى تجميعة'),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in all)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(c.name),
                      trailing: Icon(
                        c.items.contains(b.id)
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: c.items.contains(b.id) ? Brand.blue : Brand.line,
                      ),
                      onTap: () => c.items.contains(b.id)
                          ? Collections.instance.take(c, b.id)
                          : Collections.instance.add(c, b.id),
                    ),
                  ListTile(
                    leading: Icon(Icons.add, color: Brand.blue),
                    title: const Text('تجميعة جديدة'),
                    onTap: () async {
                      final n = await askName(context, title: 'اسم التجميعة');
                      if (n == null) return;
                      Collections.instance.add(
                        Collections.instance.create(n),
                        b.id,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      );
    },
  ),
);
