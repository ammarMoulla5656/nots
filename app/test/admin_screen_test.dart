import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/stats/admin_api.dart';
import 'package:nots/stats/admin_screen.dart';
import 'package:nots/sync/google_account.dart';
import 'package:nots/ui/theme.dart';

const _now = 1794330182680;

/// Answers shaped as the server's (tools/server/api/admin.php).
final _answers = <String, dynamic>{
  'overview': {
    'users': 412,
    'devices': 455,
    'signedIn': 190,
    'syncDevices': 170,
    'active': {'day': 61, 'week': 203, 'month': 350},
    'newWeek': 18,
    'readHours': 2310.5,
    'hoursPerUser': 5.6,
    'cleanHours': 120.2,
    'cleanUsers': 88,
    'countries': {'IQ': 300, 'LB': 40, 'IR': 30, 'SE': 5, '': 2},
    'tools': {'pen': 9000, 'hl': 4000, 'eraser': 1200, 'lasso': 300},
    'features': {'search': 800, 'toc': 650, 'clean_screen': 120, 'odd': 2},
    'hours': [for (var h = 0; h < 24; h++) (h * 7 % 13).toDouble()],
    'cleanByHour': [for (var h = 0; h < 24; h++) (h % 5).toDouble()],
    'weekdays': [10, 20, 30, 25, 40, 50, 15],
    'network': {'wifi': 1500.2, 'mobile': 600.1, 'offline': 210},
    'apps': {'1.0.0': 400, '0.9.0': 55},
    'androids': {'14': 200, '13': 150},
    'models': {'TECNO KJ5': 40, 'Samsung SM-A155F': 30},
    'avgLibraryMB': 210.4,
    'avgItems': 9.2,
    'daily': [
      for (var i = 1; i <= 30; i++)
        {
          'day': '2026-10-${i.toString().padLeft(2, '0')}',
          'users': i * 3,
          'hours': i,
        },
    ],
    'openMessages': 7,
  },
  'books': {
    'books': [
      {
        'id': 'b1',
        't': 'منهاج الصالحين - العبادات، طبعة جديدة منقحة ومزيدة',
        'a': 'السيد السيستاني',
        's': 'الفقه',
        'holders': 120,
        'readers': 90,
        'downloads': 140,
        'views': 500,
        'hours': 410.5,
        'progress': 37,
        'use': 75,
      },
    ],
    'own': [
      {'t': 'محاضرات في الأصول', 'a': '', 'users': 4},
    ],
  },
  'users': [
    {
      'key': 'a@b.com',
      'email': 'a@b.com',
      'name': 'علي محمد',
      'cc': 'IQ',
      'devices': 2,
      'first': _now - 9e9,
      'last': _now,
      'hours': 12.5,
      'items': 14,
      'own': 2,
      'sync': true,
      'app': '1.0.0',
    },
    {
      'key': 'dev:x',
      'email': null,
      'name': 'TECNO KJ5',
      'cc': 'LB',
      'devices': 1,
      'first': _now,
      'last': _now,
      'hours': 0.2,
      'items': 1,
      'own': 0,
      'sync': false,
      'app': '1.0.0',
    },
  ],
  'messages': [
    {
      'id': 'x:1',
      'kind': 'book',
      'text': 'أقترح إضافة كتاب الكافي بطبعة دار الحديث',
      'about': 'الكافي',
      'at': _now,
      'done': 0,
      'email': 'a@b.com',
      'name': 'علي',
      'cc': 'IQ',
      'model': 'KJ5',
    },
    {
      'id': 'x:2',
      'kind': 'problem',
      'text': 'الصفحة 30 لا تظهر',
      'about': null,
      'at': _now,
      'done': 1,
      'email': null,
      'name': null,
      'cc': '',
      'model': 'KJ5',
    },
  ],
  'admins': {
    'owner': 'ammargmaes1@gmail.com',
    'admins': [
      {
        'email': 'helper@gmail.com',
        'added': _now,
        'by': 'ammargmaes1@gmail.com',
      },
    ],
  },
  'user': {
    'key': 'a@b.com',
    'email': 'a@b.com',
    'name': 'علي محمد',
    'devices': [
      {
        'id': 'd1',
        'model': 'TECNO KJ5',
        'android': '14',
        'app': '1.0.0',
        'first': _now - 9e9,
        'last': _now,
        'reports': 30,
        'ip': '37.236.0.9',
        'cc': 'IQ',
        'hz': 120.0,
        'screen': '1080x2400',
        'lang': 'ar-IQ',
        'freeMB': 4768,
        'totalMB': 61035,
        'linked': true,
        'ips': [
          {'ip': '37.236.0.9', 'country': 'IQ', 'first': _now, 'last': _now},
          {'ip': '5.1.83.1', 'country': 'DE', 'first': _now, 'last': _now},
        ],
        'library': {
          'items': 14,
          'here': 10,
          'notes': 3,
          'own': 2,
          'collections': 2,
          'bytes': 210000000,
        },
      },
    ],
    'totals': {
      'readHours': 12.5,
      'appHours': 20,
      'cleanHours': 1.2,
      'wifiHours': 15,
      'mobileHours': 4,
      'offlineHours': 1,
      'sessions': 40,
      'opens': 70,
      'launches': 50,
    },
    'hours': [for (var h = 0; h < 24; h++) h / 10],
    'cleanByHour': [for (var h = 0; h < 24; h++) 0],
    'weekdays': [1, 2, 3, 4, 5, 6, 7],
    'tools': {'pen': 90, 'hl': 30},
    'features': {'search': 9},
    'settings': {'fingerDraws': true, 'keepAwake': false},
    'books': [
      {
        'id': 'k',
        't': 'الكافي',
        'a': 'الكليني',
        'kind': 'library',
        'hours': 4.2,
        'opens': 12,
        'page': 120,
        'far': 140,
        'pages': 600,
        'last': _now,
        'tools': {'pen': 40},
        'f': {'toc': 3},
      },
      {
        'id': 'n',
        't': 'ملاحظة',
        'a': '',
        'kind': 'note',
        'hours': 0.3,
        'opens': 2,
        'page': 1,
        'far': 1,
        'pages': 0,
        'last': _now,
        'tools': <String, dynamic>{},
        'f': <String, dynamic>{},
      },
    ],
    'own': [],
    'daily': [],
    'messages': [
      {'kind': 'book', 'text': 'الكافي', 'about': null, 'at': _now, 'done': 0},
    ],
  },
};

class _FakeApi extends AdminApi {
  _FakeApi() : super(GoogleAccount());

  @override
  Future<dynamic> get(
    String action, [
    Map<String, String> args = const {},
  ]) async => _answers[action];
}

Future<void> _show(WidgetTester t, Size size) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: AdminScreen(account: GoogleAccount(), owner: true, api: _FakeApi()),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  for (final (name, size) in [
    ('phone', const Size(360, 780)),
    ('small phone', const Size(320, 640)),
    ('tablet', const Size(1180, 820)),
  ]) {
    testWidgets('$name: every tab shows its answers and fits', (t) async {
      await _show(t, size);
      expect(find.text('كل المستخدمين'), findsOneWidget);
      expect(find.text('412'), findsOneWidget);
      // Scroll the general tab to its end: every card is laid out.
      await t.drag(find.byType(ListView).first, const Offset(0, -8000));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);

      for (final tab in ['الكتب', 'المستخدمون', 'الرسائل', 'المدراء']) {
        await t.ensureVisible(find.text(tab));
        await t.pumpAndSettle();
        await t.tap(find.text(tab));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: tab);
      }
      expect(find.text('helper@gmail.com'), findsOneWidget);
      expect(find.text('إضافة مدير'), findsOneWidget);

      await t.ensureVisible(find.text('المستخدمون'));
      await t.pumpAndSettle();
      await t.tap(find.text('المستخدمون'));
      await t.pumpAndSettle();
      expect(find.text('علي محمد'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'لبنان');
      await t.pump();
      expect(find.text('علي محمد'), findsNothing);
      expect(find.textContaining('بلا حساب'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, '');
      await t.pump();

      await t.tap(find.text('علي محمد'));
      await t.pumpAndSettle();
      expect(find.text('جهاز: TECNO KJ5'), findsOneWidget);
      await t.drag(find.byType(ListView).last, const Offset(0, -8000));
      await t.pumpAndSettle();
      expect(find.textContaining('وصل ص 120 من 600'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
