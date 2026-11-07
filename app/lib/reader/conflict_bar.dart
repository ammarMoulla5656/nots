import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sync/conflicts.dart';

/// Over a page written on from two devices: shows each version on the page
/// itself, and settles on the one chosen. On other pages, a reminder of the
/// pages still waiting.
class ConflictBar extends StatelessWidget {
  const ConflictBar({
    super.key,
    required this.session,
    required this.page,
    required this.onGoTo,
    required this.onAccepted,
  });

  final ConflictSession session;

  /// The page on the screen.
  final int page;
  final ValueChanged<int> onGoTo;

  /// The page was settled; the argument brings the question back.
  final ValueChanged<PageConflict> onAccepted;

  int? get _next {
    final all = session.pages;
    return all.firstWhere((n) => n > page, orElse: () => all.first);
  }

  String _time(DateTime t) {
    final l = t.toLocal();
    final h = l.hour.toString().padLeft(2, '0');
    final m = l.minute.toString().padLeft(2, '0');
    return '${l.year}/${l.month}/${l.day} $h:$m';
  }

  Widget _waiting(BuildContext context) {
    final n = session.pages.length;
    return ActionChip(
      avatar: const Icon(Icons.merge_type, size: 18),
      label: Text(n == 1 ? 'صفحة تنتظر اختيارك' : '$n صفحات تنتظر اختيارك'),
      onPressed: () => onGoTo(_next!),
    );
  }

  Widget _deciding(BuildContext context, PageConflict c) {
    final theme = Theme.of(context);
    final others = session.pages.length - 1;
    final device = deviceLabel(c.device);
    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'كُتب على هذه الصفحة من جهازين',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              '$device، ${_time(c.at)}',
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            SegmentedButton<PageChoice>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(
                  value: PageChoice.mine,
                  label: Text('هذا الجهاز'),
                ),
                ButtonSegment(
                  value: PageChoice.theirs,
                  label: Text(
                    device,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const ButtonSegment(
                  value: PageChoice.merged,
                  label: Text('دمج'),
                ),
              ],
              selected: {c.choice},
              onSelectionChanged: (s) => session.show(c.page, s.first),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                final done = await session.accept(c.page);
                if (done != null) onAccepted(done);
              },
              child: const Text('اعتماد ما يظهر الآن'),
            ),
            if (others > 0)
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: session.mergeAll,
                      child: Text('دمج الصفحات كلها (${others + 1})'),
                    ),
                  ),
                  TextButton(
                    onPressed: () => onGoTo(_next!),
                    child: const Text('الصفحة التالية'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (session.isEmpty) return const SizedBox.shrink();
    final c = session.of(page);
    return Center(
      child: SizedBox(
        width: c == null
            ? null
            : math.min(440, MediaQuery.sizeOf(context).width - 24),
        child: c == null ? _waiting(context) : _deciding(context, c),
      ),
    );
  }
}
