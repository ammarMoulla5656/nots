import 'package:flutter/material.dart';

import 'google_account.dart';
import 'sync_engine.dart';

/// The user's Google Drive: linking, state of the sync, and unlinking.
class SyncSheet extends StatefulWidget {
  const SyncSheet({super.key, required this.account, required this.sync});

  final GoogleAccount account;
  final SyncEngine sync;

  @override
  State<SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<SyncSheet> {
  bool _linking = false;
  String? _error;

  Future<void> _link() async {
    setState(() {
      _linking = true;
      _error = null;
    });
    try {
      await widget.account.link();
      await widget.sync.syncNow();
    } on SignInCancelled {
      // The user stepped back: nothing to say.
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _linking = false);
  }

  Future<void> _unlink() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء ربط الحساب؟'),
        content: const Text(
          'تبقى كتبك وكتابتك في هذا الجهاز وفي درايف كما هي، لكن المزامنة تتوقف.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إلغاء الربط'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.account.unlink();
    await widget.sync.reset();
  }

  String _status(SyncEngine s) {
    if (s.running) return 'جارٍ المزامنة…';
    final e = s.lastError;
    if (e != null) return e;
    final t = s.lastSync;
    if (t == null) return 'لم تتم المزامنة بعد.';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return 'آخر مزامنة $h:$m';
  }

  Widget _linkedView() => ListenableBuilder(
    listenable: widget.sync,
    builder: (context, _) {
      final s = widget.sync;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_done_outlined),
            title: Text(widget.account.email ?? 'حساب Google'),
            subtitle: Text(_status(s)),
          ),
          FilledButton.icon(
            onPressed: s.running ? null : s.syncNow,
            icon: const Icon(Icons.sync),
            label: const Text('زامن الآن'),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: _unlink, child: const Text('إلغاء ربط الحساب')),
        ],
      );
    },
  );

  Widget _unlinkedView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text(
        'تُحفظ في درايف الكتب التي كتبت عليها فقط: كتابتك وعلاماتك والمكان الذي وصلت إليه. إن أعدت تثبيت التطبيق وربطت حسابك تظهر كتبك فوراً، وتنزّل مع كل ما عملته عليها.',
      ),
      const SizedBox(height: 16),
      if (!GoogleConfig.ready)
        const Text('الربط بـ Google غير مهيأ في هذه النسخة من التطبيق.')
      else
        FilledButton.icon(
          onPressed: _linking ? null : _link,
          icon: _linking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: const Text('ربط حساب Google'),
        ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.account,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Google Drive', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (widget.account.linked) _linkedView() else _unlinkedView(),
        ],
      ),
    ),
  );
}
