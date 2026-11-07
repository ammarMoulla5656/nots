import 'package:flutter/material.dart';

import '../notes/paper.dart';
import '../sync/google_account.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'library_store.dart';

/// "My notes": the papers made in the app, outside any book.
class NotesTab extends StatelessWidget {
  const NotesTab({
    super.key,
    required this.library,
    required this.account,
    required this.onOpen,
    required this.onMore,
    required this.onAccount,
    required this.onHistory,
    required this.onNew,
  });

  final LibraryStore library;
  final GoogleAccount account;
  final void Function(BookEntry) onOpen;
  final void Function(BookEntry) onMore;
  final VoidCallback onAccount;
  final VoidCallback onHistory;
  final VoidCallback onNew;

  static String when(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final d = today.difference(day).inDays;
    if (d <= 0) return 'اليوم';
    if (d == 1) return 'أمس';
    if (d < 7) return 'قبل $d أيام';
    return '${t.year}/${t.month}/${t.day}';
  }

  Widget _hero() => HeroHeader(
    child: Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ملاحظاتي',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                  height: 1.2,
                ),
              ),
              Text(
                'أوراقك خارج الكتب',
                style: TextStyle(color: Color(0xFFCFDDF0), fontSize: 12.5),
              ),
            ],
          ),
        ),
        HeroButton(
          icon: Icons.schedule,
          tooltip: 'آخر ١٠ كتب',
          onPressed: onHistory,
        ),
        const SizedBox(width: 8),
        ListenableBuilder(
          listenable: account,
          builder: (_, _) => HeroButton(
            icon: Icons.person_outline,
            photo: account.photo,
            tooltip: 'الحساب',
            dot: account.linked,
            onPressed: onAccount,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final notes = [for (final b in library.books) if (b.isNote) b];
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _hero()),
            if (notes.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 40, 28, 130),
                  child: Column(
                    children: [
                      Icon(Icons.edit_note, size: 60, color: Brand.line),
                      const SizedBox(height: 12),
                      Text(
                        'لا ملاحظات بعد.\n\nاضغط النجمة لتبدأ ورقة بيضاء، أو اختر قالباً من قوالب طالب العلم.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Brand.muted, height: 1.7),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.tonalIcon(
                        onPressed: onNew,
                        icon: const Icon(Icons.add),
                        label: const Text('ورقة جديدة'),
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  sidePadding(context),
                  0,
                  sidePadding(context),
                  130,
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, c) {
                    final w = c.crossAxisExtent;
                    final cols = (w / 160).floor().clamp(2, 8);
                    const gap = 14.0;
                    final cell = (w - gap * (cols - 1)) / cols;
                    return SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _NoteCard(
                          note: notes[i],
                          onTap: () => onOpen(notes[i]),
                          onMore: () => onMore(notes[i]),
                        ),
                        childCount: notes.length,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: gap,
                        mainAxisSpacing: 18,
                        mainAxisExtent: cell * 297 / 210 + 56,
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.onTap,
    required this.onMore,
  });

  final BookEntry note;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x1416233A),
                        blurRadius: 14,
                        offset: Offset(0, 5),
                      ),
                    ],
                  ),
                  child: PaperPreview(PaperStyle.parse(note.author)),
                ),
              ),
              const SizedBox(height: 9),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 22),
                child: Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                  ),
                ),
              ),
              Text(
                NotesTab.when(note.lastOpened),
                style: TextStyle(fontSize: 12, color: Brand.muted),
              ),
            ],
          ),
        ),
        PositionedDirectional(
          end: -6,
          bottom: 0,
          child: SizedBox(
            width: 30,
            height: 34,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: 'خيارات',
              icon: Icon(Icons.more_horiz, size: 18, color: Brand.muted),
              onPressed: onMore,
            ),
          ),
        ),
      ],
    );
  }
}
