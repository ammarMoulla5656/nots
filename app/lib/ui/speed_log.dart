import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// "Speed measuring": while on, the app writes how long its steps take and
/// how smooth its frames are to `speed.log`, and shows the frame graph.
/// While off it costs nothing: every call returns at once.
///
/// The log is in the app's folder on the phone's shared storage
/// (`/sdcard/Android/data/<package>/files/speed.log`), so it can be taken
/// with `adb pull` or shared from the app.
///
/// The switch stays on this device: it is not one of the settings that go
/// to the account.
class SpeedLog extends ChangeNotifier {
  SpeedLog._();

  static final instance = SpeedLog._();

  /// Time since the app started, for every line.
  static final _clock = Stopwatch()..start();

  bool enabled = false;

  /// What the user is looking at, written with the frame lines.
  String screen = 'start';

  Directory? _dir;
  IOSink? _sink;
  Timer? _flush;

  /// Folders; tests may point them elsewhere.
  static Future<Directory> Function() dirProvider = () async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    } on Object {
      // not on Android
    }
    return getApplicationSupportDirectory();
  };

  Future<File> get _flag async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'speed-mode'));

  File? get file => _dir == null ? null : File(p.join(_dir!.path, 'speed.log'));

  /// Reads whether measuring was left on.
  Future<void> load() async {
    try {
      if (await (await _flag).exists()) await _start();
    } on Object {
      // no folder yet: off
    }
  }

  Future<void> setEnabled(bool on) async {
    if (on == enabled) return;
    final flag = await _flag;
    if (on) {
      await flag.writeAsString('1', flush: true);
      await _start();
      note('measuring on');
    } else {
      note('measuring off');
      await _stop();
      if (await flag.exists()) await flag.delete();
    }
  }

  Future<void> _start() async {
    final dir = _dir = await dirProvider();
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, 'speed.log'));
    // Keep it readable: a long log starts again, the last part kept.
    if (await f.exists() && await f.length() > 4 * 1024 * 1024) {
      await f.rename(p.join(dir.path, 'speed.old.log'));
    }
    _sink = f.openWrite(mode: FileMode.append);
    enabled = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _flush = Timer.periodic(const Duration(seconds: 5), (_) => _frameLine());
    _sink!.writeln(
      '\n===== ${DateTime.now().toIso8601String()} · '
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion} · '
      'cpus ${Platform.numberOfProcessors} =====',
    );
    notifyListeners();
  }

  Future<void> _stop() async {
    enabled = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _flush?.cancel();
    final s = _sink;
    _sink = null;
    await s?.flush();
    await s?.close();
    notifyListeners();
  }

  void _write(String kind, String text) {
    final s = _sink;
    if (s == null) return;
    final t = _clock.elapsedMilliseconds;
    final mb = (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(0);
    s.writeln(
      '${(t / 1000).toStringAsFixed(3).padLeft(9)}s  ${mb.padLeft(4)}MB  '
      '${screen.padRight(9)} $kind  $text',
    );
  }

  /// Something happened (no duration).
  void note(String text) {
    if (enabled) _write('·', text);
  }

  /// A step took [ms] milliseconds.
  void took(String what, int ms, [String extra = '']) {
    if (enabled) _write('⏱', '$what ${ms}ms${extra.isEmpty ? '' : '  $extra'}');
  }

  /// Runs [body] and writes how long it took.
  Future<T> span<T>(String what, Future<T> Function() body) async {
    if (!enabled) return body();
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      took(what, sw.elapsedMilliseconds);
    }
  }

  /// The same for work that does not wait.
  T spanSync<T>(String what, T Function() body) {
    if (!enabled) return body();
    final sw = Stopwatch()..start();
    try {
      return body();
    } finally {
      took(what, sw.elapsedMilliseconds);
    }
  }

  // ---- frames: one line every few seconds while something moves

  int _frames = 0, _over16 = 0, _over33 = 0;
  int _worstBuild = 0, _worstRaster = 0;
  int _sumBuild = 0, _sumRaster = 0;

  void _onTimings(List<FrameTiming> list) {
    for (final f in list) {
      final b = f.buildDuration.inMicroseconds;
      final r = f.rasterDuration.inMicroseconds;
      final total = f.totalSpan.inMicroseconds;
      _frames++;
      if (total > 16667) _over16++;
      if (total > 33334) _over33++;
      if (b > _worstBuild) _worstBuild = b;
      if (r > _worstRaster) _worstRaster = r;
      _sumBuild += b;
      _sumRaster += r;
    }
  }

  void _frameLine() {
    if (_frames > 0) {
      String ms(int us) => (us / 1000).toStringAsFixed(1);
      _write(
        '▦',
        'frames $_frames  slow>16ms $_over16  >33ms $_over33  '
            'build avg ${ms(_sumBuild ~/ _frames)} max ${ms(_worstBuild)}  '
            'raster avg ${ms(_sumRaster ~/ _frames)} max ${ms(_worstRaster)}',
      );
    }
    _frames = _over16 = _over33 = 0;
    _worstBuild = _worstRaster = _sumBuild = _sumRaster = 0;
    unawaited(_sink?.flush());
  }

  /// Everything written so far, on disk now (before sharing it).
  Future<void> flushNow() async {
    _frameLine();
    await _sink?.flush();
  }

  Future<void> clear() async {
    final f = file;
    final was = enabled;
    if (was) await _stop();
    if (f != null && await f.exists()) await f.delete();
    if (was) await _start();
  }
}
