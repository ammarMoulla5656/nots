import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sync/google_account.dart';
import 'usage_upload.dart' show statsBase;

class AdminError implements Exception {
  AdminError(this.message, {this.code = 0});

  final String message;
  final int code;

  @override
  String toString() => message;
}

/// The administrators' questions to the server. The server asks Google which
/// account the Drive token belongs to, and answers administrators only.
class AdminApi {
  AdminApi(this.account);

  final GoogleAccount account;

  Future<dynamic> get(
    String action, [
    Map<String, String> args = const {},
  ]) async {
    if (!account.linked) {
      throw AdminError('سجّل الدخول بحساب Google أولاً.', code: 401);
    }
    final uri = Uri.parse('${statsBase}admin.php')
        .replace(queryParameters: {'a': action, ...args});
    Future<http.Response> ask(String token) => http
        .get(
          uri,
          headers: {'Authorization': 'Bearer $token', 'X-Nots-Token': token},
        )
        .timeout(const Duration(seconds: 40));
    var r = await ask(await account.accessToken());
    if (r.statusCode == 401) {
      r = await ask(await account.accessToken(renew: true));
    }
    if (r.statusCode == 403) {
      throw AdminError('هذا الحساب ليس من الإدارة.', code: 403);
    }
    if (r.statusCode != 200) {
      throw AdminError(
        'تعذّر الاتصال بالسيرفر (${r.statusCode}).',
        code: r.statusCode,
      );
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// Whether the signed-in account is an administrator (false on any
  /// failure: the panel simply does not open).
  Future<({bool admin, bool owner})> whoAmI() async {
    try {
      final j = await get('whoami') as Map;
      return (admin: j['admin'] == true, owner: j['owner'] == true);
    } on Object {
      return (admin: false, owner: false);
    }
  }
}
