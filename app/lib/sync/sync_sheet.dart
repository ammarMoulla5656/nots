import 'package:flutter/material.dart';

import '../catalog/catalog_screen.dart' show formatSize;
import '../library/library_store.dart';
import '../ui/app_settings.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'drive_client.dart';
import 'google_account.dart';
import 'sync_engine.dart';

/// The user's account: signing in and out, the state of the sync, the room
/// left in Drive, and moving to another account.
class SyncSheet extends StatefulWidget {
  const SyncSheet({
    super.key,
    required this.account,
    required this.sync,
    required this.beforeWipe,
  });

  final GoogleAccount account;
  final SyncEngine sync;

  /// Stops what still writes into the library.
  final VoidCallback beforeWipe;

  @override
  State<SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<SyncSheet> {
  /// What a long step is doing; the buttons wait meanwhile.
  String? _working;
  String? _error;

  GoogleAccount get _account => widget.account;
  SyncEngine get _sync => widget.sync;

  Future<void> _step(String what, Future<void> Function() job) async {
    setState(() {
      _working = what;
      _error = null;
    });
    try {
      await job();
    } on SignInCancelled {
      // The user stepped back: nothing to say.
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _working = null);
  }

  Future<T?> _ask<T>({
    required String title,
    required String text,
    required List<(String, T)> choices,
    T? danger,
  }) => showDialog<T>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(text)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('تراجع'),
        ),
        for (final (label, value) in choices)
          value == danger && danger != null
              ? TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(context, value),
                  child: Text(label),
                )
              : FilledButton(
                  onPressed: () => Navigator.pop(context, value),
                  child: Text(label),
                ),
      ],
    ),
  );

  /// Signing in. When this device holds the data of another account, it
  /// stays that account's unless the user says to move it.
  Future<void> _signIn() => _step('جارٍ تسجيل الدخول…', () async {
    await _account.link();
    if (await _sync.otherAccountsData()) {
      final owner = await _sync.owner();
      final email = _account.email;
      if (!mounted) return;
      final move = await _ask<bool>(
        title: 'بيانات حساب آخر',
        text:
            'الكتب والكتابة التي على هذا الجهاز تخص $owner.\n\nهل تنقلها إلى $email؟ تبقى نسختها في درايف الحساب الأول كما هي.',
        choices: [('انقلها', true)],
      );
      if (move != true) {
        await _account.unlink();
        return;
      }
      await _sync.moveTo(email);
    }
    await _sync.syncNow();
  });

  String _titles(List<BookEntry> books) {
    final names = books.take(5).map((b) => '• ${b.title}').join('\n');
    final more = books.length > 5 ? '\nو${books.length - 5} غيرها' : '';
    return '$names$more';
  }

  /// Signing out. The data leaves this device only when Drive holds it, or
  /// when the user, told what would be lost, says so twice.
  Future<void> _signOut() async {
    final ok = await _ask<bool>(
      title: 'تسجيل الخروج؟',
      text: 'يُرفع كل عملك إلى درايف أولاً، ثم تُحذف كتبك وكتابتك من هذا الجهاز. تعود كلها عند تسجيل الدخول بهذا الحساب.',
      choices: [('تسجيل الخروج', true)],
    );
    if (ok != true) return;
    await _step('جارٍ حفظ كل شيء في درايف…', () async {
      var left = await _sync.saveEverything();
      while (left.isNotEmpty) {
        if (!mounted) return;
        final why = _sync.driveFull
            ? 'درايف ممتلئ.'
            : (_sync.lastError ?? 'تعذّر الرفع.');
        final choice = await _ask<String>(
          title: 'لم يُحفظ كل شيء',
          text:
              '$why\n\nلم يصل هذا إلى درايف بعد:\n${_titles(left)}\n\nلم يُحذف شيء من جهازك.',
          choices: [
            ('أعد المحاولة', 'retry'),
            ('انقل إلى حساب آخر', 'move'),
            ('احذف رغم ذلك', 'lose'),
          ],
          danger: 'lose',
        );
        if (choice == 'retry') {
          left = await _sync.saveEverything();
          continue;
        }
        if (choice == 'move') {
          await _moveNow();
          return;
        }
        if (choice != 'lose' || !mounted) return;
        final sure = await _ask<bool>(
          title: 'حذف نهائي',
          text: 'سيضيع ما لم يُرفع ولا يمكن استرجاعه:\n${_titles(left)}',
          choices: [('احذف نهائياً', true)],
          danger: true,
        );
        if (sure != true) return;
        break;
      }
      widget.beforeWipe();
      await _account.unlink();
      await _sync.wipeDevice();
    });
  }

  /// Moving: this device's copy of everything goes to the account chosen.
  /// Nothing is removed anywhere, and the sign-in comes before any change.
  Future<void> _move() async {
    final ok = await _ask<bool>(
      title: 'نقل كل شيء إلى حساب آخر',
      text: 'تُجمع كتبك وكتابتك على هذا الجهاز، ثم تختار الحساب الجديد وتُرفع إليه. لا يُحذف شيء قبل تسجيل الدخول، وتبقى نسخة الحساب الحالي في درايف الخاص به.',
      choices: [('متابعة', true)],
    );
    if (ok != true) return;
    await _step('جارٍ جمع بياناتك…', _moveNow);
  }

  Future<void> _moveNow() async {
    final old = _account.email;
    final missing = await _sync.gatherEverything();
    if (missing.isNotEmpty) {
      if (!mounted) return;
      final go = await _ask<bool>(
        title: 'كتب لم تصل إلى الجهاز',
        text:
            'لن تنتقل ملفات هذه الكتب، وتبقى في درايف الحساب الحالي:\n${_titles(missing)}',
        choices: [('تابع دونها', true)],
      );
      if (go != true) return;
    }
    await _account.link(chooseAccount: true);
    if (_account.email == old) {
      _error = 'اخترت الحساب نفسه، فلم يتغير شيء.';
      return;
    }
    await _sync.moveTo(_account.email);
    await _sync.syncNow();
  }

  String _status() {
    final s = _sync;
    if (s.activity != null) return s.activity!;
    if (s.running) return 'جارٍ المزامنة…';
    final e = s.lastError;
    if (e != null) return e;
    final t = s.lastSync;
    if (t == null) return 'لم تتم المزامنة بعد.';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return 'آخر مزامنة $h:$m';
  }

  Widget _room(DriveQuota q) {
    final limit = q.limit;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Google Drive', style: TextStyle(fontSize: 13)),
              if (q.left != null)
                Text(
                  'المتبقي ${formatSize(q.left!)}',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w900,
                    color: q.nearlyFull ? Brand.red : Brand.blue,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (q.share != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: q.share,
                minHeight: 5,
                color: q.nearlyFull ? Brand.red : Brand.blue,
              ),
            ),
          const SizedBox(height: 6),
          Text(
            limit == null
                ? 'مستعمل ${formatSize(q.used)}'
                : 'مستعمل ${formatSize(q.used)} من ${formatSize(limit)}',
            style: TextStyle(fontSize: 12.5, color: Brand.muted),
          ),
        ],
      ),
    );
  }

  Widget _fullWarning() {
    final full = _sync.driveFull;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBEFD6),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Text(
        full
            ? 'درايف ممتلئ. عملك محفوظ على هذا الجهاز، لكن الجديد لن يُرفع حتى تُفرغ مساحة أو تنقل كل شيء إلى حساب آخر.'
            : 'درايف يقترب من الامتلاء. أفرغ مساحة، أو انقل كل شيء إلى حساب آخر.',
        style: const TextStyle(color: Color(0xFF6B4E12), height: 1.6),
      ),
    );
  }

  /// The blue card at the top: who is signed in.
  Widget _who(String name, String sub) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(19),
      gradient: const LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Color(0xFF2159A3), Brand.blueNight],
      ),
    ),
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.person_outline, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                sub,
                style: const TextStyle(color: Color(0xFFD5E1F2), fontSize: 12.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _switchRow(
    IconData icon,
    String title,
    String? sub,
    bool on,
    ValueChanged<bool> set,
  ) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 12.5)),
    trailing: Switch(value: on, onChanged: set),
    onTap: () => set(!on),
  );

  Widget _settings() => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) {
      final s = AppSettings.instance;
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _switchRow(
              Icons.dark_mode_outlined,
              'الوضع الليلي',
              'ألوان هادئة للعين في الظلام',
              s.darkMode,
              s.setDarkMode,
            ),
            const Divider(),
            _switchRow(
              Icons.touch_app_outlined,
              'الإصبع يرسم',
              'أطفئه ليكتب القلم وحده ويحرّك الإصبعُ الصفحة',
              s.fingerDraws,
              s.setFingerDraws,
            ),
            const Divider(),
            _switchRow(
              Icons.light_mode_outlined,
              'تبقى الشاشة مضاءة أثناء الدرس',
              null,
              s.keepAwake,
              s.setKeepAwake,
            ),
          ],
        ),
      );
    },
  );

  Widget _rights() => Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Brand.blue,
      borderRadius: BorderRadius.circular(17),
    ),
    child: Row(
      children: [
        Image.asset('assets/images/alhikmeh-white-logo.webp', height: 56),
        const SizedBox(width: 14),
        const Expanded(
          child: Text(
            'جميع الحقوق محفوظة © ٢٠٢٦ مؤسسة الحكمة للثقافة الإسلامية',
            style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.7),
          ),
        ),
      ],
    ),
  );

  Widget _signedIn() => ListenableBuilder(
    listenable: _sync,
    builder: (context, _) {
      final s = _sync;
      final q = s.quota;
      final busy = s.running || _working != null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _who(_account.email ?? 'حساب Google', 'كتابتك محفوظة في Google Drive'),
          const SizedBox(height: 12),
          if (s.driveFull || (q?.nearlyFull ?? false)) _fullWarning(),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    s.needsSignIn ? Icons.login : Icons.cloud_done_outlined,
                  ),
                  title: Text(s.needsSignIn ? 'سجّل الدخول مرة أخرى' : 'زامن الآن'),
                  subtitle: Text(_working ?? _status()),
                  onTap: busy ? null : (s.needsSignIn ? _signIn : s.syncNow),
                ),
                if (q != null) _room(q),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _settings(),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.drive_file_move_outline),
                  title: const Text('نقل كل شيء إلى حساب آخر'),
                  onTap: busy ? null : _move,
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout, color: Brand.red),
                  title: const Text(
                    'تسجيل الخروج',
                    style: TextStyle(color: Brand.red),
                  ),
                  onTap: busy ? null : _signOut,
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _signedOut() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      _who('غير مسجَّل الدخول', 'سجّل الدخول لتُحفظ كتبك'),
      Padding(
        padding: EdgeInsets.fromLTRB(4, 12, 4, 12),
        child: Text(
          'سجّل الدخول لتُحفظ كل كتبك وكتابتك في درايف، وتظهر على أي جهاز تدخل منه. الكتب التي أضفتها من جهازك تُرفع مع تعديلاتك، وكتب المكتبة تُرفع تعديلاتك عليها فقط.',
          style: TextStyle(color: Brand.muted, height: 1.7),
        ),
      ),
      if (!GoogleConfig.ready)
        const Text('الربط بـ Google غير مهيأ في هذه النسخة من التطبيق.')
      else
        FilledButton.icon(
          onPressed: _working != null ? null : _signIn,
          icon: _working != null
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: const Text('تسجيل الدخول بحساب Google'),
        ),
      const SizedBox(height: 12),
      _settings(),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _account,
    builder: (context, _) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHeader(''),
            if (_account.linked) _signedIn() else _signedOut(),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Brand.red)),
            ],
            _rights(),
          ],
        ),
      ),
    ),
  );
}
