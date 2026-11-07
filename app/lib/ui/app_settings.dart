import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Choices of the person using the app, kept across runs: whether a finger
/// writes (or only the pen does), and whether the screen stays lit during a
/// lesson.
class AppSettings extends ChangeNotifier {
  AppSettings({
    this.fingerDraws = true,
    this.keepAwake = true,
    this.darkMode = false,
    this.nightPages = true,
  });

  /// The one shared by the whole app.
  static final instance = AppSettings();

  /// A finger writes. When off, only the pen writes and a finger moves the
  /// page (palm rejection).
  bool fingerDraws;

  /// The screen stays lit while a book is open.
  bool keepAwake;

  /// The night look: deep navy instead of paper.
  bool darkMode;

  /// In the night look the pages of books are shown light on dark too
  /// (their colours turned over); off, they stay as printed.
  bool nightPages;

  File? _file;

  /// Where the settings are kept; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'prefs'));

  Future<void> load() async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    final f = _file = File(p.join(dir.path, 'settings.json'));
    if (!await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      fingerDraws = j['finger'] as bool? ?? fingerDraws;
      keepAwake = j['awake'] as bool? ?? keepAwake;
      darkMode = j['dark'] as bool? ?? darkMode;
      nightPages = j['night'] as bool? ?? nightPages;
      notifyListeners();
    } on FormatException {
      // A damaged file only brings back the usual choices.
    }
  }

  void setFingerDraws(bool v) {
    if (v == fingerDraws) return;
    fingerDraws = v;
    _changed();
  }

  void setKeepAwake(bool v) {
    if (v == keepAwake) return;
    keepAwake = v;
    _changed();
  }

  void setDarkMode(bool v) {
    if (v == darkMode) return;
    darkMode = v;
    _changed();
  }

  void setNightPages(bool v) {
    if (v == nightPages) return;
    nightPages = v;
    _changed();
  }

  void _changed() {
    notifyListeners();
    _file?.writeAsString(
      jsonEncode({
        'finger': fingerDraws,
        'awake': keepAwake,
        'dark': darkMode,
        'night': nightPages,
      }),
    );
  }

  /// Applies the screen-lit choice. [reading] is true while a book is open.
  Future<void> applyAwake({required bool reading}) async {
    try {
      if (reading && keepAwake) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } on Object {
      // A platform without the feature simply keeps its own behaviour.
    }
  }
}
