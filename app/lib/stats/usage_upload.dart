import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../library/collections.dart';
import '../library/library_store.dart';
import '../reader/reader_prefs.dart';
import '../ui/app_settings.dart';
import 'usage.dart';

/// The app's statistics service on the server (under nots/ only).
const statsBase = 'https://alhikmeh.org/alhawzaapp/publiclibdata/nots/api/';

/// Sent with every report: not a secret, it only keeps stray requests out.
const statsKey = 'nots-usage-1';

/// A message for the administrators: a book to add, or a problem.
class FeedbackOutbox {
  FeedbackOutbox._();

  static final instance = FeedbackOutbox._();

  List<Map<String, dynamic>> _items = [];
  File? _file;

  List<Map<String, dynamic>> get waiting => List.unmodifiable(_items);

  Future<void> load() async {
    final dir = await Usage.dirProvider();
    await dir.create(recursive: true);
    final f = _file = File(p.join(dir.path, 'outbox.json'));
    try {
      if (await f.exists()) {
        _items = (jsonDecode(await f.readAsString()) as List)
            .cast<Map<String, dynamic>>();
      }
    } on Object {
      _items = [];
    }
  }

  /// [kind] is 'book' (a book to add) or 'problem'.
  Future<void> add(String kind, String text, {String? about}) async {
    if (_file == null) await load();
    _items.add({
      'id': '${DateTime.now().microsecondsSinceEpoch}',
      'kind': kind,
      'text': text,
      if (about != null && about.isNotEmpty) 'about': about,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    await _save();
  }

  /// The messages the server took.
  Future<void> sent(Iterable<String> ids) async {
    final gone = ids.toSet();
    _items.removeWhere((m) => gone.contains(m['id']));
    await _save();
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    await f.writeAsString(jsonEncode(_items), flush: true);
  }
}

/// Sends what Usage recorded, with a picture of the library and the device,
/// to the server: only over Wi-Fi, never on mobile data; only in a quiet
/// moment (not while a book is open); at most every few hours, sooner when a
/// message waits. Each report is the whole picture, so a lost one costs
/// nothing.
class UsageUploader {
  UsageUploader({
    required this.library,
    required this.account,
    required this.reading,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  final LibraryStore library;

  /// The linked account: email and name, or nulls.
  final ({String? email, String? name, bool linked}) Function() account;

  /// Whether a book is open in the reader now.
  final bool Function() reading;

  static const every = Duration(hours: 6);
  static const _channel = MethodChannel('nots/app');

  bool _busy = false;
  DateTime _tried = DateTime(0);

  /// Called each minute the app is in front.
  Future<void> tick() async {
    final u = Usage.instance;
    if (_busy || reading() || !u.sharing) return;
    if (u.network != 'wifi') return;
    final now = DateTime.now();
    final sentAt = DateTime.fromMillisecondsSinceEpoch(
      u.data['sent'] as int? ?? 0,
    );
    final messages = FeedbackOutbox.instance.waiting.isNotEmpty;
    final due =
        now.difference(sentAt) > every ||
        (messages && now.difference(_tried) > const Duration(minutes: 2));
    if (!due) return;
    // After a failure, wait a while before trying again.
    if (!messages && now.difference(_tried) < const Duration(minutes: 20)) {
      return;
    }
    _tried = now;
    await send();
  }

  /// Sends now (when on Wi-Fi). True when the server took it.
  Future<bool> send() async {
    if (_busy) return false;
    _busy = true;
    try {
      final report = await this.report();
      final ids = [
        for (final m in report['messages'] as List) (m as Map)['id'] as String,
      ];
      final body = await Isolate.run(
        () => gzip.encode(utf8.encode(jsonEncode(report))),
      );
      final r = await _client
          .post(
            Uri.parse('${statsBase}collect.php'),
            headers: {
              'Content-Type': 'application/octet-stream',
              'X-Nots-Key': statsKey,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 40));
      if (r.statusCode != 200) return false;
      Usage.instance.data['sent'] = DateTime.now().millisecondsSinceEpoch;
      await Usage.instance.save();
      if (ids.isNotEmpty) await FeedbackOutbox.instance.sent(ids);
      return true;
    } on Object {
      return false;
    } finally {
      _busy = false;
    }
  }

  /// What is sent: the whole picture of this device.
  Future<Map<String, dynamic>> report() async {
    final u = Usage.instance;
    final acc = account();
    Map<String, dynamic> device = {};
    try {
      device = Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('deviceInfo') ?? {},
      );
    } on Object {
      device = {'os': Platform.operatingSystem};
    }
    // The library as it is now.
    final books = library.books;
    var bytes = 0, here = 0, notes = 0, own = 0, offloaded = 0;
    final catalog = <Map<String, Object?>>[];
    final owned = <Map<String, Object?>>[];
    for (final b in books) {
      final on = library.isOnDevice(b);
      if (on) {
        here++;
        bytes += b.size;
      }
      if (b.offloaded) offloaded++;
      if (b.isNote) {
        notes++;
      } else if (b.catalogId != null) {
        catalog.add({'c': b.catalogId, 'p': b.part, 'on': on});
      } else {
        own++;
        owned.add({'t': b.title, 'a': b.author, 'size': b.size});
      }
    }
    // Where each book was left (read from small files, in a quiet moment).
    final usage = jsonDecode(jsonEncode(u.data)) as Map<String, dynamic>;
    final ub = (usage['books'] as Map?) ?? {};
    for (final id in ub.keys) {
      final pr = await ReaderPrefs.peekProgress(id as String);
      if (pr != null) {
        final m = ub[id] as Map;
        m['pg'] = pr.page;
        if (pr.count > 0) m['n'] = pr.count;
      }
    }
    final s = AppSettings.instance;
    return {
      'v': 1,
      'device': {...device, 'id': u.deviceId},
      'account': {'email': acc.email, 'name': acc.name, 'linked': acc.linked},
      'library': {
        'items': books.length,
        'here': here,
        'notes': notes,
        'own': own,
        'offloaded': offloaded,
        'bytes': bytes,
        'collections': Collections.instance.all.length,
        'catalog': catalog,
        'ownBooks': owned,
      },
      'settings': {'fingerDraws': s.fingerDraws, 'keepAwake': s.keepAwake},
      'usage': usage,
      'messages': FeedbackOutbox.instance.waiting,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
  }
}
