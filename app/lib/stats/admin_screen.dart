import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../reader/tool_layout.dart' show ReaderTool;
import '../sync/google_account.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'admin_api.dart';

/// The administrators' panel: who uses the app, how, where, and which books;
/// the messages users sent; and who else administers it.
class AdminScreen extends StatelessWidget {
  const AdminScreen({
    super.key,
    required this.account,
    required this.owner,
    this.api,
  });

  final GoogleAccount account;
  final bool owner;

  /// The server's answers; tests give their own.
  final AdminApi? api;

  static Future<void> open(
    BuildContext context,
    GoogleAccount account, {
    required bool owner,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AdminScreen(account: account, owner: owner),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final api = this.api ?? AdminApi(account);
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        backgroundColor: Brand.paper,
        appBar: AppBar(
          title: const Text('لوحة الإدارة'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'عام'),
              Tab(text: 'الكتب'),
              Tab(text: 'المستخدمون'),
              Tab(text: 'الرسائل'),
              Tab(text: 'المدراء'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _Loaded(api: api, action: 'overview', build: _overview),
            _Loaded(api: api, action: 'books', build: _books),
            _Users(api: api),
            _Messages(api: api),
            _Admins(api: api, owner: owner),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ helpers

num _n(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;

Map<String, num> _map(Object? v) => {
  if (v is Map)
    for (final e in v.entries) '${e.key}': _n(e.value),
};

List<num> _list(Object? v) => [
  if (v is List)
    for (final x in v) _n(x),
];

String _date(Object? ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(_n(ms).toInt());
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 60) return 'قبل ${d.inMinutes} د';
  if (d.inHours < 24) return 'قبل ${d.inHours} س';
  if (d.inDays < 30) return 'قبل ${d.inDays} يوم';
  return '${t.year}/${t.month}/${t.day}';
}

String _hours(Object? h) {
  final v = _n(h).toDouble();
  if (v < 1) return '${(v * 60).round()} د';
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} س';
}

const _countries = {
  'IQ': 'العراق',
  'IR': 'إيران',
  'LB': 'لبنان',
  'SA': 'السعودية',
  'KW': 'الكويت',
  'BH': 'البحرين',
  'SY': 'سوريا',
  'AE': 'الإمارات',
  'QA': 'قطر',
  'OM': 'عُمان',
  'YE': 'اليمن',
  'JO': 'الأردن',
  'EG': 'مصر',
  'TR': 'تركيا',
  'AZ': 'أذربيجان',
  'PK': 'باكستان',
  'IN': 'الهند',
  'AF': 'أفغانستان',
  'US': 'أمريكا',
  'CA': 'كندا',
  'GB': 'بريطانيا',
  'DE': 'ألمانيا',
  'SE': 'السويد',
  'NL': 'هولندا',
  'DK': 'الدنمارك',
  'NO': 'النرويج',
  'FR': 'فرنسا',
  'BE': 'بلجيكا',
  'AU': 'أستراليا',
  'NZ': 'نيوزيلندا',
  'FI': 'فنلندا',
  'AT': 'النمسا',
  'IT': 'إيطاليا',
  'ES': 'إسبانيا',
  'RU': 'روسيا',
  'NG': 'نيجيريا',
  'TZ': 'تنزانيا',
  'KE': 'كينيا',
  'ZA': 'جنوب أفريقيا',
  'MY': 'ماليزيا',
  'ID': 'إندونيسيا',
};

String country(String cc) => _countries[cc] ?? (cc.isEmpty ? '؟' : cc);

const _features = {
  'search': 'البحث في الكتاب',
  'toc': 'الفهرس',
  'copy': 'نسخ نص',
  'share': 'مشاركة',
  'share_text': 'مشاركة نص محدد',
  'export': 'تصدير',
  'bookmark': 'علامة مرجعية',
  'clean_screen': 'الشاشة الصافية',
  'masdar': 'فتح في المصدر',
  'add_page': 'إضافة صفحة',
  'link_word': 'ربط ملف Word',
  'picture': 'إضافة صورة',
  'ruler': 'المسطرة',
  'recent': 'آخر المواضع',
  'pages': 'صفحات الكتاب',
  'library_search': 'البحث في كتبي',
  'catalog_search': 'البحث في الكتب',
  'collection': 'إنشاء تجميعة',
  'new_note': 'ورقة جديدة',
  'add_file': 'إضافة ملف',
  'suggest_book': 'اقتراح كتاب',
  'report_problem': 'إبلاغ عن مشكلة',
};

String _feature(String k) => _features[k] ?? k;
String _tool(String k) => ReaderTool.byId(k)?.label ?? k;

/// A list loaded from the server, again on a pull.
class _Loaded extends StatefulWidget {
  const _Loaded({required this.api, required this.action, required this.build});

  final AdminApi api;
  final String action;
  final Widget Function(BuildContext, dynamic) build;

  @override
  State<_Loaded> createState() => _LoadedState();
}

class _LoadedState extends State<_Loaded> with AutomaticKeepAliveClientMixin {
  late Future<dynamic> _f = widget.api.get(widget.action);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<dynamic>(
      future: _f,
      builder: (context, s) {
        if (s.hasError) return _Failed('${s.error}', () => setState(_reload));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        return RefreshIndicator(
          onRefresh: () async {
            setState(_reload);
            await _f;
          },
          child: widget.build(context, s.data),
        );
      },
    );
  }

  void _reload() => _f = widget.api.get(widget.action);
}

class _Failed extends StatelessWidget {
  const _Failed(this.text, this.retry);

  final String text;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: retry, child: const Text('إعادة المحاولة')),
        ],
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card(this.title, this.child);

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

/// Numbers side by side, each with its label.
class _Figures extends StatelessWidget {
  const _Figures(this.items);

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (label, value) in items)
        Container(
          width: 104,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: Brand.tint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  color: Brand.blue,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: Brand.muted),
              ),
            ],
          ),
        ),
    ],
  );
}

/// Bars, longest first: a name, a bar, a number.
class _Bars extends StatelessWidget {
  const _Bars(this.values, {this.label = _same, this.max = 12});

  final Map<String, num> values;
  final String Function(String) label;
  final int max;

  static String _same(String s) => s;

  @override
  Widget build(BuildContext context) {
    final e = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = e.take(max).toList();
    if (top.isEmpty) {
      return Text('لا شيء بعد.', style: TextStyle(color: Brand.muted));
    }
    final most = top.first.value <= 0 ? 1 : top.first.value;
    return Column(
      children: [
        for (final x in top)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 118,
                  child: Text(
                    label(x.key),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FractionallySizedBox(
                      widthFactor: (x.value / most).clamp(0.02, 1.0).toDouble(),
                      child: Container(
                        height: 12,
                        decoration: BoxDecoration(
                          color: Brand.blue,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    '${x.value is double ? (x.value as double).toStringAsFixed(1) : x.value}',
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 12, color: Brand.muted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Upright bars in a row: the hours of the day, the days of the week.
class _Columns extends StatelessWidget {
  const _Columns(this.values, this.labels);

  final List<num> values;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final most = values.fold<num>(0, (a, b) => b > a ? b : a);
    return Column(
      children: [
        SizedBox(
          height: 90,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final v in values)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: FractionallySizedBox(
                      heightFactor: most <= 0
                          ? 0.02
                          : (v / most).clamp(0.02, 1.0).toDouble(),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Brand.blue,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final l in labels)
              Expanded(
                child: Text(
                  l,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 9.5, color: Brand.muted),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

final _hourLabels = [for (var h = 0; h < 24; h++) h % 3 == 0 ? '$h' : ''];
const _dayLabels = ['اثن', 'ثلا', 'أرب', 'خمي', 'جمع', 'سبت', 'أحد'];

Widget _page(List<Widget> children) => ListView(
  padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
  physics: const AlwaysScrollableScrollPhysics(),
  children: children,
);

// ------------------------------------------------------------------ tabs

Widget _overview(BuildContext context, dynamic d) {
  final m = d as Map;
  final active = m['active'] as Map? ?? {};
  final daily = [for (final x in (m['daily'] as List? ?? [])) x as Map];
  return _page([
    _Card(
      'المستخدمون',
      _Figures([
        ('كل المستخدمين', '${m['users']}'),
        ('الأجهزة', '${m['devices']}'),
        ('بحساب Google', '${m['signedIn']}'),
        ('اليوم', '${active['day']}'),
        ('هذا الأسبوع', '${active['week']}'),
        ('هذا الشهر', '${active['month']}'),
        ('جدد هذا الأسبوع', '${m['newWeek']}'),
        ('أجهزة تزامن مع درايف', '${m['syncDevices']}'),
        ('رسائل جديدة', '${m['openMessages']}'),
      ]),
    ),
    _Card(
      'القراءة',
      _Figures([
        ('ساعات القراءة', _hours(m['readHours'])),
        ('لكل مستخدم', _hours(m['hoursPerUser'])),
        ('الشاشة الصافية', _hours(m['cleanHours'])),
        ('يستعملون الصافية', '${m['cleanUsers']}'),
        ('متوسط حجم المكتبة', '${m['avgLibraryMB']} م.ب'),
        ('متوسط عدد الكتب', '${m['avgItems']}'),
      ]),
    ),
    if (daily.isNotEmpty)
      _Card(
        'آخر 30 يوماً: من قرأ كل يوم',
        _Columns(
          [for (final x in daily) _n(x['users'])],
          [
            for (var i = 0; i < daily.length; i++)
              i % 5 == 0 ? '${daily[i]['day']}'.substring(8) : '',
          ],
        ),
      ),
    _Card('ساعات القراءة في اليوم', _Columns(_list(m['hours']), _hourLabels)),
    _Card(
      'متى تُستعمل الشاشة الصافية',
      _Columns(_list(m['cleanByHour']), _hourLabels),
    ),
    _Card('أيام الأسبوع', _Columns(_list(m['weekdays']), _dayLabels)),
    _Card('أكثر الأدوات استعمالاً', _Bars(_map(m['tools']), label: _tool)),
    _Card('الميزات', _Bars(_map(m['features']), label: _feature, max: 30)),
    _Card('الدول', _Bars(_map(m['countries']), label: country, max: 30)),
    _Card(
      'الاتصال أثناء الاستعمال (ساعات)',
      _Bars(
        _map(m['network']),
        label: (k) => switch (k) {
          'wifi' => 'واي فاي',
          'mobile' => 'بيانات الهاتف',
          _ => 'بلا إنترنت',
        },
      ),
    ),
    _Card('إصدارات التطبيق', _Bars(_map(m['apps']))),
    _Card('إصدارات أندرويد', _Bars(_map(m['androids']))),
    _Card('الأجهزة', _Bars(_map(m['models']))),
  ]);
}

Widget _books(BuildContext context, dynamic d) {
  final m = d as Map;
  final books = [for (final x in (m['books'] as List? ?? [])) x as Map];
  final own = [for (final x in (m['own'] as List? ?? [])) x as Map];
  return _page([
    Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        'مرتبة بعدد القرّاء. «نسبة الاستعمال»: من قرأ الكتاب (دقيقة فأكثر) من بين من نزّله.',
        style: TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.6),
      ),
    ),
    for (final b in books)
      Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${b['t']}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                '${b['a']} · ${b['s']}',
                style: TextStyle(color: Brand.muted, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _pair('نزّلوه', '${b['downloads']}'),
                  _pair('عندهم الآن', '${b['holders']}'),
                  _pair('قرؤوه', '${b['readers']}'),
                  _pair('نسبة الاستعمال', '${b['use']}%'),
                  _pair('ساعات', _hours(b['hours'])),
                  _pair('متوسط التقدم', '${b['progress']}%'),
                  _pair('مشاهدات الصفحة', '${b['views']}'),
                ],
              ),
            ],
          ),
        ),
      ),
    if (own.isNotEmpty)
      _Card(
        'كتب أضافها المستخدمون من أجهزتهم (${own.length})',
        Column(
          children: [
            for (final o in own)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${o['t']}'),
                subtitle: '${o['a']}'.isEmpty ? null : Text('${o['a']}'),
                trailing: Text('${o['users']} مستخدم'),
              ),
          ],
        ),
      ),
  ]);
}

Widget _pair(String label, String value) => Text.rich(
  TextSpan(
    children: [
      TextSpan(
        text: '$label: ',
        style: TextStyle(color: Brand.muted, fontSize: 12),
      ),
      TextSpan(
        text: value,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      ),
    ],
  ),
);

// ------------------------------------------------------------------ users

class _Users extends StatefulWidget {
  const _Users({required this.api});

  final AdminApi api;

  @override
  State<_Users> createState() => _UsersState();
}

class _UsersState extends State<_Users> with AutomaticKeepAliveClientMixin {
  late Future<dynamic> _f = widget.api.get('users');
  String _q = '';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<dynamic>(
      future: _f,
      builder: (context, s) {
        if (s.hasError) {
          return _Failed(
            '${s.error}',
            () => setState(() => _f = widget.api.get('users')),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final q = _q.trim().toLowerCase();
        final all = [for (final x in s.data as List) x as Map];
        final shown = [
          for (final u in all)
            if (q.isEmpty ||
                '${u['email']} ${u['name']} ${country('${u['cc']}')}'
                    .toLowerCase()
                    .contains(q))
              u,
        ];
        return RefreshIndicator(
          onRefresh: () async {
            setState(() => _f = widget.api.get('users'));
            await _f;
          },
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
            itemCount: shown.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText:
                          'ابحث بالاسم أو البريد أو البلد (${all.length})',
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                );
              }
              final u = shown[i - 1];
              final email = '${u['email'] ?? ''}';
              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  title: Text(
                    email.isEmpty
                        ? 'بلا حساب · ${u['name'] ?? ''}'
                        : '${u['name'] ?? email}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      if (email.isNotEmpty) email,
                      country('${u['cc']}'),
                      '${_hours(u['hours'])} قراءة',
                      '${u['items']} كتاب',
                      if (_n(u['devices']) > 1) '${u['devices']} أجهزة',
                      if (u['sync'] == true) 'يزامن',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(
                    _date(u['last']),
                    style: TextStyle(fontSize: 11.5, color: Brand.muted),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _UserScreen(api: widget.api, user: u),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _UserScreen extends StatelessWidget {
  const _UserScreen({required this.api, required this.user});

  final AdminApi api;
  final Map user;

  @override
  Widget build(BuildContext context) {
    final email = '${user['email'] ?? ''}';
    return Scaffold(
      backgroundColor: Brand.paper,
      appBar: AppBar(title: Text(email.isEmpty ? '${user['name']}' : email)),
      body: _Loaded(
        api: _KeyedApi(api, user['key'] as String),
        action: 'user',
        build: _detail,
      ),
    );
  }

  static Widget _detail(BuildContext context, dynamic d) {
    final m = d as Map;
    final t = m['totals'] as Map? ?? {};
    final devices = [for (final x in (m['devices'] as List? ?? [])) x as Map];
    final books = [for (final x in (m['books'] as List? ?? [])) x as Map];
    final msgs = [for (final x in (m['messages'] as List? ?? [])) x as Map];
    final settings = m['settings'] as Map? ?? {};
    return _page([
      _Card(
        '${m['name'] ?? ''}',
        _Figures([
          ('ساعات القراءة', _hours(t['readHours'])),
          ('في التطبيق', _hours(t['appHours'])),
          ('الشاشة الصافية', _hours(t['cleanHours'])),
          ('على واي فاي', _hours(t['wifiHours'])),
          ('على البيانات', _hours(t['mobileHours'])),
          ('بلا إنترنت', _hours(t['offlineHours'])),
          ('مرات فتح التطبيق', '${t['launches']}'),
          ('مرات فتح كتاب', '${t['opens']}'),
        ]),
      ),
      for (final dv in devices) _device(context, dv),
      _Card('متى يقرأ', _Columns(_list(m['hours']), _hourLabels)),
      _Card(
        'متى يستعمل الشاشة الصافية',
        _Columns(_list(m['cleanByHour']), _hourLabels),
      ),
      _Card('أيام الأسبوع', _Columns(_list(m['weekdays']), _dayLabels)),
      _Card('الأدوات', _Bars(_map(m['tools']), label: _tool)),
      _Card('الميزات', _Bars(_map(m['features']), label: _feature, max: 30)),
      _Card(
        'الإعدادات',
        Text(
          [
            'الإصبع يرسم: ${settings['fingerDraws'] == true ? 'نعم' : 'لا'}',
            'الشاشة مضاءة أثناء الدرس: ${settings['keepAwake'] == true ? 'نعم' : 'لا'}',
          ].join('\n'),
          style: const TextStyle(height: 1.8),
        ),
      ),
      _Card(
        'كتبه (${books.length})',
        Column(
          children: [
            for (final b in books)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${b['t']}${b['kind'] == 'own'
                          ? '  (أضافه من جهازه)'
                          : b['kind'] == 'note'
                          ? '  (ملاحظة)'
                          : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      [
                        '${_hours(b['hours'])} قراءة',
                        '${b['opens']} مرة',
                        if (_n(b['pages']) > 0)
                          'وصل ص ${b['page']} من ${b['pages']} (أبعد ${b['far']})',
                        'آخر فتح ${_date(b['last'])}',
                      ].join(' · '),
                      style: TextStyle(fontSize: 12, color: Brand.muted),
                    ),
                    if (_map(b['tools']).isNotEmpty || _map(b['f']).isNotEmpty)
                      Text(
                        [
                          for (final e in _map(b['tools']).entries)
                            '${_tool(e.key)} ${e.value}',
                          for (final e in _map(b['f']).entries)
                            '${_feature(e.key)} ${e.value}',
                        ].join('، '),
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (msgs.isNotEmpty)
        _Card(
          'رسائله',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final x in msgs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${x['kind'] == 'book' ? 'اقتراح كتاب' : 'مشكلة'} · ${_date(x['at'])}\n${x['about'] ?? ''}\n${x['text']}'
                        .replaceAll('\n\n', '\n'),
                  ),
                ),
            ],
          ),
        ),
    ]);
  }

  static Widget _device(BuildContext context, Map dv) {
    final lib = dv['library'] as Map? ?? {};
    final ips = [for (final x in (dv['ips'] as List? ?? [])) x as Map];
    return _Card(
      'جهاز: ${dv['model']}',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            [
              'أندرويد ${dv['android']} · التطبيق ${dv['app']}',
              if (dv['hz'] != null)
                'الشاشة ${dv['screen']} بتردد ${_n(dv['hz']).round()} هرتز',
              'أول ظهور ${_date(dv['first'])} · آخر ظهور ${_date(dv['last'])} · ${dv['reports']} تقرير',
              'آخر عنوان: ${dv['ip']} (${country('${dv['cc']}')})',
              if (dv['freeMB'] != null)
                'المساحة الفارغة ${(_n(dv['freeMB']) / 1024).toStringAsFixed(1)} من ${(_n(dv['totalMB']) / 1024).toStringAsFixed(0)} غ.ب',
              'المكتبة: ${lib['items']} عنصر، ${lib['here']} على الجهاز، ${lib['notes']} ملاحظة، ${lib['own']} من جهازه، ${lib['collections']} تجميعة، ${(_n(lib['bytes']) / 1048576).toStringAsFixed(0)} م.ب',
              'يزامن مع درايف: ${dv['linked'] == true ? 'نعم' : 'لا'}',
            ].join('\n'),
            style: const TextStyle(fontSize: 12.5, height: 1.8),
          ),
          if (ips.length > 1) ...[
            const SizedBox(height: 6),
            Text(
              'العناوين',
              style: TextStyle(color: Brand.muted, fontSize: 12),
            ),
            for (final ip in ips)
              Text(
                '${ip['ip']} · ${country('${ip['country']}')} · ${_date(ip['last'])}',
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ],
      ),
    );
  }
}

/// The same questions about one user.
class _KeyedApi extends AdminApi {
  _KeyedApi(this.inner, this.key) : super(inner.account);

  final AdminApi inner;
  final String key;

  @override
  Future<dynamic> get(String action, [Map<String, String> args = const {}]) =>
      inner.get(action, {...args, 'id': key});
}

// ------------------------------------------------------------------ messages

class _Messages extends StatefulWidget {
  const _Messages({required this.api});

  final AdminApi api;

  @override
  State<_Messages> createState() => _MessagesState();
}

class _MessagesState extends State<_Messages>
    with AutomaticKeepAliveClientMixin {
  late Future<dynamic> _f = widget.api.get('messages');
  String _kind = 'all';

  @override
  bool get wantKeepAlive => true;

  void _reload() => setState(() => _f = widget.api.get('messages'));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<dynamic>(
      future: _f,
      builder: (context, s) {
        if (s.hasError) return _Failed('${s.error}', _reload);
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final all = [for (final x in s.data as List) x as Map];
        final shown = [
          for (final x in all)
            if (_kind == 'all' || x['kind'] == _kind) x,
        ];
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _f;
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
            children: [
              Pills(
                labels: const ['الكل', 'اقتراح كتاب', 'مشكلة'],
                selected: switch (_kind) {
                  'book' => 'اقتراح كتاب',
                  'problem' => 'مشكلة',
                  _ => 'الكل',
                },
                onSelected: (k) => setState(
                  () => _kind = switch (k) {
                    'اقتراح كتاب' => 'book',
                    'مشكلة' => 'problem',
                    _ => 'all',
                  },
                ),
              ),
              const SizedBox(height: 10),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'لا رسائل.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Brand.muted),
                  ),
                ),
              for (final x in shown)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: x['done'] == 1 ? Brand.wash : null,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              x['kind'] == 'book'
                                  ? Icons.menu_book_outlined
                                  : Icons.report_problem_outlined,
                              size: 18,
                              color: Brand.blue,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${x['name'] ?? x['email'] ?? x['model'] ?? ''} · ${country('${x['cc'] ?? ''}')} · ${_date(x['at'])}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Brand.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if ('${x['about'] ?? ''}'.isNotEmpty)
                          Text(
                            '${x['about']}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        SelectableText(
                          '${x['text']}',
                          style: const TextStyle(height: 1.7),
                        ),
                        if ('${x['email'] ?? ''}'.isNotEmpty)
                          SelectableText(
                            '${x['email']}',
                            style: TextStyle(fontSize: 12, color: Brand.muted),
                          ),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton(
                            onPressed: () async {
                              await widget.api.get('done', {
                                'id': '${x['id']}',
                                'v': x['done'] == 1 ? '0' : '1',
                              });
                              _reload();
                            },
                            child: Text(
                              x['done'] == 1 ? 'إرجاعها جديدة' : 'تمت معالجتها',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ admins

class _Admins extends StatefulWidget {
  const _Admins({required this.api, required this.owner});

  final AdminApi api;
  final bool owner;

  @override
  State<_Admins> createState() => _AdminsState();
}

class _AdminsState extends State<_Admins> {
  late Future<dynamic> _f = widget.api.get('admins');
  final _email = TextEditingController();
  String? _error;

  void _reload() => setState(() => _f = widget.api.get('admins'));

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _change(String action, String email) async {
    setState(() => _error = null);
    try {
      await widget.api.get(action, {'email': email});
      _email.clear();
      _reload();
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
    future: _f,
    builder: (context, s) {
      if (s.hasError) return _Failed('${s.error}', _reload);
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final m = s.data as Map;
      final admins = [for (final x in (m['admins'] as List? ?? [])) x as Map];
      return _page([
        Text(
          'المدير يرى هذه اللوحة حين يسجّل الدخول بحسابه في Google داخل التطبيق، ثم يضغط سبع مرات على شعار مؤسسة الحكمة أسفل صفحة الحساب.',
          style: TextStyle(color: Brand.muted, height: 1.7),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: SelectableText('${m['owner']}'),
            subtitle: const Text('صاحب التطبيق'),
          ),
        ),
        for (final a in admins)
          Card(
            child: ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: SelectableText('${a['email']}'),
              subtitle: Text('أضيف ${_date(a['added'])}'),
              trailing: widget.owner
                  ? IconButton(
                      tooltip: 'إزالة',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _change('removeAdmin', '${a['email']}'),
                    )
                  : null,
            ),
          ),
        if (widget.owner) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textDirection: TextDirection.ltr,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            decoration: const InputDecoration(
              labelText: 'بريد حساب Google لمدير جديد',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _change('addAdmin', _email.text.trim()),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('إضافة مدير'),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: Brand.red)),
          ),
      ]);
    },
  );
}
