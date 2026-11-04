import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// The app's identity at Google. These are given at build time (see
/// app/GOOGLE_SETUP.md); they are public by design for an
/// installed app, and hold no access to anyone's data.
class GoogleConfig {
  /// Web client id: Google's sign-in on devices with Google services.
  static const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  /// Desktop client: the browser sign-in, for devices without them.
  static const browserClientId = String.fromEnvironment(
    'GOOGLE_BROWSER_CLIENT_ID',
  );
  static const browserClientSecret = String.fromEnvironment(
    'GOOGLE_BROWSER_CLIENT_SECRET',
  );

  static bool get ready => webClientId.isNotEmpty || browserReady;
  static bool get browserReady => browserClientId.isNotEmpty;

  /// The app's own hidden folder in Drive, and nothing else of the user's.
  static const driveScope = 'https://www.googleapis.com/auth/drive.appdata';
}

/// The user closed the sign-in without finishing it.
class SignInCancelled implements Exception {}

/// The result of a browser sign-in.
class BrowserTokens {
  const BrowserTokens(this.refreshToken, this.accessToken, this.expiresIn, this.email);

  final String refreshToken;
  final String accessToken;
  final int expiresIn;
  final String? email;
}

String _randomUrlSafe(int bytes) {
  final r = Random.secure();
  return base64UrlEncode([
    for (var i = 0; i < bytes; i++) r.nextInt(256),
  ]).replaceAll('=', '');
}

/// The challenge of [verifier] (PKCE, S256).
@visibleForTesting
String pkceChallenge(String verifier) => base64UrlEncode(
  sha256.convert(ascii.encode(verifier)).bytes,
).replaceAll('=', '');

/// The email inside a Google id token, read without checking its signature:
/// it came straight from Google over TLS, and is only shown to the user.
@visibleForTesting
String? emailOfIdToken(String? idToken) {
  final parts = idToken?.split('.');
  if (parts == null || parts.length != 3) return null;
  try {
    final j = jsonDecode(utf8.decode(base64Url.decode(base64.normalize(parts[1]))));
    return (j as Map)['email'] as String?;
  } on FormatException {
    return null;
  }
}

const _doneHtml = '''<!doctype html><html dir="rtl" lang="ar"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<body style="font-family:sans-serif;text-align:center;padding:3em 1em">
<h2>تم ربط الحساب</h2><p>ارجع إلى تطبيق نوتس.</p></body></html>''';

/// Sign-in in a browser tab shown over the app, for devices without Google
/// services. Google refuses sign-in inside an app's own web view
/// (disallowed_useragent), so this is a Custom Tab; the answer comes back to
/// a small server on this device (the loopback flow, with PKCE).
class BrowserSignIn {
  BrowserSignIn({http.Client? client, required this.open})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Shows the sign-in page.
  final Future<void> Function(Uri url) open;

  static final _tokenUrl = Uri.parse('https://oauth2.googleapis.com/token');

  Future<BrowserTokens> signIn() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}';
      final verifier = _randomUrlSafe(48);
      final state = _randomUrlSafe(16);
      await open(
        Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
          'client_id': GoogleConfig.browserClientId,
          'redirect_uri': redirect,
          'response_type': 'code',
          'scope': 'openid email ${GoogleConfig.driveScope}',
          'code_challenge': pkceChallenge(verifier),
          'code_challenge_method': 'S256',
          'state': state,
          'access_type': 'offline',
          'prompt': 'consent',
        }),
      );
      final code = await _awaitCode(server, state);
      final r = await _client.post(
        _tokenUrl,
        body: {
          'client_id': GoogleConfig.browserClientId,
          'client_secret': GoogleConfig.browserClientSecret,
          'code': code,
          'code_verifier': verifier,
          'grant_type': 'authorization_code',
          'redirect_uri': redirect,
        },
      );
      if (r.statusCode != 200) throw 'رفض Google الربط (${r.statusCode}).';
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return BrowserTokens(
        j['refresh_token'] as String,
        j['access_token'] as String,
        (j['expires_in'] as num).toInt(),
        emailOfIdToken(j['id_token'] as String?),
      );
    } finally {
      await server.close(force: true);
    }
  }

  Future<String> _awaitCode(HttpServer server, String state) async {
    await for (final req in server.timeout(const Duration(minutes: 5))) {
      final q = req.uri.queryParameters;
      // The browser also asks for an icon; only Google's answer counts.
      if (q['state'] != state) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        continue;
      }
      req.response.headers.contentType = ContentType.html;
      req.response.write(_doneHtml);
      await req.response.close();
      final code = q['code'];
      if (code == null) throw SignInCancelled();
      return code;
    }
    throw SignInCancelled();
  }

  /// A new access token from a refresh token, with its life in seconds.
  /// Returns null when Google no longer accepts [refreshToken].
  Future<(String, int)?> renew(String refreshToken) async {
    final r = await _client.post(
      _tokenUrl,
      body: {
        'client_id': GoogleConfig.browserClientId,
        'client_secret': GoogleConfig.browserClientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      },
    );
    if (r.statusCode == 400 || r.statusCode == 401) return null;
    if (r.statusCode != 200) throw HttpException('${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['access_token'] as String, (j['expires_in'] as num).toInt());
  }
}

/// Google's account on this device has to be linked again.
class RelinkNeeded implements Exception {}

/// The user's linked Google account: through Google's own sign-in when the
/// device has Google services, else through a browser tab.
class GoogleAccount extends ChangeNotifier {
  static const _channel = MethodChannel('nots/app');
  static const _storage = FlutterSecureStorage();
  static const _kMode = 'google.mode';
  static const _kEmail = 'google.email';
  static const _kRefresh = 'google.refresh';

  String? _mode;
  String? _email;
  String? _refresh;
  String? _token;
  DateTime _tokenEnds = DateTime(0);
  GoogleSignInAccount? _native;
  bool _nativeReady = false;

  late final _browser = BrowserSignIn(open: _openInApp);

  bool get linked => _mode != null;
  String? get email => _email;

  Future<void> restore() async {
    _mode = await _storage.read(key: _kMode);
    _email = await _storage.read(key: _kEmail);
    _refresh = await _storage.read(key: _kRefresh);
    notifyListeners();
  }

  Future<void> _remember() async {
    await _storage.write(key: _kMode, value: _mode);
    await _storage.write(key: _kEmail, value: _email);
    await _storage.write(key: _kRefresh, value: _refresh);
    notifyListeners();
  }

  Future<bool> _hasGoogleServices() async {
    try {
      return await _channel.invokeMethod<bool>('hasGoogleServices') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _openInApp(Uri url) async {
    final tabs =
        await _channel.invokeMethod<bool>('hasCustomTabs') ?? false;
    // Without a browser offering tabs, url_launcher would fall back to a web
    // view, which Google refuses: use the browser itself.
    final ok = await launchUrl(
      url,
      mode: tabs ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication,
    );
    if (!ok) throw 'لا يوجد متصفح على هذا الجهاز.';
  }

  Future<void> _initNative() async {
    if (_nativeReady) return;
    await GoogleSignIn.instance.initialize(
      serverClientId: GoogleConfig.webClientId,
    );
    _nativeReady = true;
  }

  /// Links an account. Throws [SignInCancelled] when the user stepped back.
  Future<void> link() async {
    if (GoogleConfig.webClientId.isNotEmpty && await _hasGoogleServices()) {
      try {
        await _linkNative();
        return;
      } on GoogleSignInException catch (e) {
        if (e.code == GoogleSignInExceptionCode.canceled) {
          throw SignInCancelled();
        }
        // The services are there but do not work: the browser still does.
        if (!GoogleConfig.browserReady) rethrow;
      }
    }
    if (!GoogleConfig.browserReady) {
      throw 'تسجيل الدخول عبر المتصفح غير مهيأ في هذه النسخة.';
    }
    final t = await _browser.signIn();
    await _channel.invokeMethod<void>('bringToFront');
    _mode = 'browser';
    _email = t.email;
    _refresh = t.refreshToken;
    _token = t.accessToken;
    _tokenEnds = DateTime.now().add(Duration(seconds: t.expiresIn - 120));
    await _remember();
  }

  Future<void> _linkNative() async {
    await _initNative();
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: [GoogleConfig.driveScope],
    );
    final auth = await account.authorizationClient.authorizeScopes([
      GoogleConfig.driveScope,
    ]);
    _native = account;
    _mode = 'native';
    _email = account.email;
    _refresh = null;
    _token = auth.accessToken;
    _tokenEnds = DateTime.now().add(const Duration(minutes: 45));
    await _remember();
  }

  Future<void> unlink() async {
    if (_mode == 'native') {
      try {
        await _initNative();
        await GoogleSignIn.instance.signOut();
      } on GoogleSignInException {
        // Forget it here all the same.
      }
    }
    _mode = _email = _refresh = _token = null;
    _native = null;
    await _storage.delete(key: _kMode);
    await _storage.delete(key: _kEmail);
    await _storage.delete(key: _kRefresh);
    notifyListeners();
  }

  /// The access token for Drive. Throws [RelinkNeeded] when only the user can
  /// put things right.
  Future<String> accessToken({bool renew = false}) async {
    if (!linked) throw RelinkNeeded();
    final held = _token;
    if (!renew && held != null && DateTime.now().isBefore(_tokenEnds)) {
      return held;
    }
    return _mode == 'native' ? _nativeToken(held, renew) : _browserToken();
  }

  Future<String> _browserToken() async {
    final refresh = _refresh;
    final got = refresh == null ? null : await _browser.renew(refresh);
    if (got == null) throw RelinkNeeded();
    _token = got.$1;
    _tokenEnds = DateTime.now().add(Duration(seconds: got.$2 - 120));
    return got.$1;
  }

  Future<String> _nativeToken(String? held, bool renew) async {
    await _initNative();
    final gs = GoogleSignIn.instance;
    if (renew && held != null) {
      await gs.authorizationClient.clearAuthorizationToken(accessToken: held);
    }
    _native ??= await gs.attemptLightweightAuthentication();
    final auth = await _native?.authorizationClient.authorizationForScopes([
      GoogleConfig.driveScope,
    ]);
    if (auth == null) throw RelinkNeeded();
    _token = auth.accessToken;
    _tokenEnds = DateTime.now().add(const Duration(minutes: 45));
    return auth.accessToken;
  }
}
