import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../library/library_store.dart';

/// How the app is used on this device, kept for the administrators: the time
/// spent reading (each book, each hour of the day), the tools and features
/// used, the clean screen, and the network the app ran on.
///
/// Recording is cheap on purpose: counters in memory, a timestamp per
/// activity, a save every two minutes and when the app goes to the back.
/// Nothing is sent from here; see UsageUploader.
class Usage {
  Usage._();

  static final instance = Usage._();

  /// Where the file is kept; tests point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'prefs'));

  static const fileName = 'usage.json';

  /// A stretch without any activity counts at most this long: a phone left
  /// open on a page is not hours of reading.
  static const maxGap = Duration(minutes: 5);

  static const _channel = MethodChannel('nots/app');

  /// The time now; tests set their own.
  DateTime Function() clock = DateTime.now;

  Map<String, dynamic> _d = {};
  File? _file;
  bool _dirty = false;
  bool _loaded = false;
  Timer? _tick;
  bool _foreground = true;

  /// The network now: 'wifi', 'mobile' or 'none' (read once a minute).
  String network = 'none';

  /// The book open in the reader, and when it was last active.
  String? _book;
  DateTime? _last;
  bool _clean = false;

  /// The id of this installation (made once, never synced).
  String get deviceId => _d['dev'] as String? ?? '';

  /// Everything recorded, as stored.
  Map<String, dynamic> get data => _d;

  /// Whether the user lets the reports go to the server (on by default; a
  /// switch in the settings turns it off).
  bool get sharing => _d['share'] as bool? ?? true;
  set sharing(bool on) {
    _d['share'] = on;
    _dirty = true;
    unawaited(save());
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await dirProvider();
      await dir.create(recursive: true);
      final f = _file = File(p.join(dir.path, fileName));
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, dynamic>) _d = j;
      }
    } on Object {
      _d = {};
    }
    if ((_d['dev'] as String?)?.isNotEmpty != true) {
      final r = math.Random.secure();
      _d['dev'] = List.generate(
        16,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _d['first'] = clock().millisecondsSinceEpoch;
      _dirty = true;
    }
    _total('launches');
    _startTicking();
  }

  void _startTicking() {
    _tick?.cancel();
    unawaited(_readNetwork());
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _minute());
  }

  /// Once a minute while the app is in front: the minute goes to the
  /// network it ran on, and the file is saved every other minute.
  int _minutes = 0;
  void _minute() {
    if (!_foreground) return;
    _addTotal('app', 60);
    _addTotal(switch (network) {
      'wifi' => 'wifi',
      'mobile' => 'mobile',
      _ => 'offline',
    }, 60);
    unawaited(_readNetwork());
    if (++_minutes % 2 == 0) unawaited(save());
    onMinute?.call();
  }

  /// Called each minute in front (the uploader looks for a quiet moment).
  void Function()? onMinute;

  Future<void> _readNetwork() async {
    try {
      network = await _channel.invokeMethod<String>('network') ?? network;
    } on Object {
      // A computer or a test: no network information.
    }
  }

  /// The app went to the back or came to the front.
  void foreground(bool inFront) {
    if (inFront == _foreground) return;
    if (!inFront) {
      _accrue();
      _last = null;
      unawaited(save());
    } else {
      _last = _book == null ? null : clock();
      _total('sessions');
      unawaited(_readNetwork());
    }
    _foreground = inFront;
  }

  // Reading -----------------------------------------------------------------

  /// A book or note was opened in the reader.
  void bookOpened(BookEntry b) {
    _accrue();
    _book = b.id;
    _last = clock();
    final m = _bookMap(b);
    m['o'] = (m['o'] as int? ?? 0) + 1;
    m['last'] = clock().millisecondsSinceEpoch;
    m['t'] = b.title;
    _total('opens');
    _dirty = true;
  }

  void bookClosed() {
    _accrue();
    _book = null;
    _last = null;
    _clean = false;
    unawaited(save());
  }

  /// Anything done in the reader (a page, a touch, a tool): the time since
  /// the last one is reading.
  void activity() {
    // Called on every frame of a scroll: only the clock is read, and the
    // counting waits for two seconds to have passed.
    final last = _last;
    if (last != null && clock().difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _accrue();
  }

  /// The page in view and how many there are.
  void page(int page, int pages) {
    _accrue();
    final id = _book;
    if (id == null) return;
    final m = (_d['books'] as Map?)?[id] as Map?;
    if (m == null) return;
    m['pg'] = page;
    m['n'] = pages;
    final most = m['far'] as int? ?? 0;
    if (page > most) m['far'] = page;
  }

  /// The clean screen was switched on or off.
  void clean(bool on) {
    _accrue();
    if (on && !_clean) {
      feature('clean_screen');
    }
    _clean = on;
  }

  void _accrue() {
    final last = _last, id = _book;
    final now = clock();
    if (last == null || id == null || !_foreground) {
      if (id != null && _foreground) _last = now;
      return;
    }
    var s = now.difference(last).inMilliseconds / 1000.0;
    _last = now;
    if (s <= 0) return;
    if (s > maxGap.inSeconds) s = maxGap.inSeconds.toDouble();
    final m = (_d['books'] as Map?)?[id] as Map?;
    if (m != null) m['s'] = ((m['s'] as num? ?? 0) + s);
    _addTotal('read', s);
    _addIn('hours', now.hour, 24, s);
    _addIn('weekdays', now.weekday - 1, 7, s);
    final day = _dayKey(now);
    final days = (_d['days'] ??= <String, dynamic>{}) as Map;
    days[day] = (days[day] as num? ?? 0) + s;
    if (days.length > 130) {
      final keys = days.keys.toList()..sort();
      for (final k in keys.take(days.length - 120)) {
        days.remove(k);
      }
    }
    if (_clean) {
      _addTotal('clean', s);
      _addIn('cleanHours', now.hour, 24, s);
    }
    _dirty = true;
  }

  static String _dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  // Tools and features ------------------------------------------------------

  /// A tool of the reader was chosen.
  void tool(String id) {
    _accrue();
    _bump('tools', id);
    final b = _book;
    if (b != null) _bumpBook(b, 'tools', id);
  }

  /// A feature was used: search, contents, copy, share, export…
  void feature(String name, {String? bookId}) {
    _bump('f', name);
    final b = bookId ?? _book;
    if (b != null && ((_d['books'] as Map?)?.containsKey(b) ?? false)) {
      _bumpBook(b, 'f', name);
    }
  }

  /// A book of the library was looked at or downloaded ([kind] is 'view'
  /// or 'dl'), by its id in the library catalogue.
  void catalog(String catalogId, String kind) {
    final c = (_d['catalog'] ??= <String, dynamic>{}) as Map;
    final m = (c[catalogId] ??= <String, dynamic>{}) as Map;
    m[kind] = (m[kind] as int? ?? 0) + 1;
    _dirty = true;
  }

  void _bump(String group, String key) {
    final g = (_d[group] ??= <String, dynamic>{}) as Map;
    g[key] = (g[key] as int? ?? 0) + 1;
    _dirty = true;
  }

  void _bumpBook(String id, String group, String key) {
    final m = (_d['books'] as Map?)?[id] as Map?;
    if (m == null) return;
    final g = (m[group] ??= <String, dynamic>{}) as Map;
    g[key] = (g[key] as int? ?? 0) + 1;
  }

  void _total(String key) {
    final t = (_d['tot'] ??= <String, dynamic>{}) as Map;
    t[key] = (t[key] as int? ?? 0) + 1;
    _dirty = true;
  }

  void _addTotal(String key, num s) {
    final t = (_d['tot'] ??= <String, dynamic>{}) as Map;
    t[key] = (t[key] as num? ?? 0) + s;
    _dirty = true;
  }

  void _addIn(String key, int i, int n, num s) {
    final raw = _d[key];
    final list = raw is List && raw.length == n
        ? raw
        : (_d[key] = List<num>.filled(n, 0, growable: false));
    list[i] = (list[i] as num) + s;
  }

  Map _bookMap(BookEntry b) {
    final books = (_d['books'] ??= <String, dynamic>{}) as Map;
    return (books[b.id] ??= <String, dynamic>{
          't': b.title,
          'a': b.author,
          if (b.catalogId != null) 'c': b.catalogId,
          if (b.part != null) 'p': b.part,
          if (b.isNote) 'note': true,
          if (b.catalogId == null && !b.isNote) 'own': true,
          'first': clock().millisecondsSinceEpoch,
        })
        as Map;
  }

  /// A book left the library: its record goes too.
  void forget(String id) {
    (_d['books'] as Map?)?.remove(id);
    _dirty = true;
  }

  /// Saves one after another: two at once would share the temporary file.
  Future<void> _saving = Future.value();
  Future<void> save() => _saving = _saving.then((_) => _saveNow());

  Future<void> _saveNow() async {
    final f = _file;
    if (!_dirty || f == null) return;
    _dirty = false;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_d), flush: true);
      await tmp.rename(f.path);
    } on Object {
      _dirty = true;
    }
  }

  /// For tests: forget everything held.
  void resetForTest() {
    _tick?.cancel();
    _saving = Future.value();
    _d = {};
    _file = null;
    _loaded = false;
    _book = null;
    _last = null;
    _foreground = true;
    _clean = false;
  }
}
