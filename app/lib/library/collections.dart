import 'dart:convert';
import 'dart:io';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One collection (تجميعة): a name and the books and notes put in it, by
/// their ids. A book or a note can be in several.
class Collection {
  Collection({
    required this.id,
    required this.name,
    List<String>? items,
    DateTime? changed,
    this.deleted = false,
  }) : items = items ?? [],
       changed = changed ?? DateTime.now();

  final String id;
  String name;

  /// Ids of the books and notes, in the order they were put in.
  final List<String> items;

  /// When it last changed: of two devices' versions the later one wins.
  DateTime changed;

  /// Removed: kept as a mark, so another device does not bring it back.
  bool deleted;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'items': items,
    'changed': changed.toUtc().toIso8601String(),
    if (deleted) 'deleted': true,
  };

  static Collection? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    if (id is! String || name is! String) return null;
    return Collection(
      id: id,
      name: name,
      items: [for (final i in (j['items'] as List? ?? const [])) '$i'],
      changed: DateTime.tryParse(j['changed'] as String? ?? ''),
      deleted: j['deleted'] == true,
    );
  }
}

/// The user's collections, kept on the device and in the account (as one
/// small file among the settings that follow the user).
class Collections extends ChangeNotifier {
  Collections();

  static final instance = Collections();

  final _all = <String, Collection>{};
  final _random = math.Random();
  File? _file;

  /// Where the file is kept; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'prefs'));

  static const fileName = 'collections.json';

  /// The collections, in the order they were made.
  List<Collection> get all => [
    for (final c in _all.values)
      if (!c.deleted) c,
  ];

  Collection? byId(String id) => _all[id]?.deleted ?? true ? null : _all[id];

  /// The collections [itemId] is in.
  List<Collection> containing(String itemId) => [
    for (final c in all)
      if (c.items.contains(itemId)) c,
  ];

  Future<void> load() async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    final f = _file = File(p.join(dir.path, fileName));
    if (!await f.exists()) return;
    try {
      _merge(await f.readAsString(), save: false);
    } on FormatException {
      // A damaged file only starts with none.
    }
  }

  Collection create(String name) {
    final c = Collection(
      // The time, and a random part: two made in one instant differ.
      id: 'c${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}',
      name: name.trim().isEmpty ? 'تجميعة' : name.trim(),
    );
    _all[c.id] = c;
    _changed(c);
    return c;
  }

  void rename(Collection c, String name) {
    if (name.trim().isEmpty) return;
    c.name = name.trim();
    _changed(c);
  }

  void remove(Collection c) {
    c
      ..deleted = true
      ..items.clear();
    _changed(c);
  }

  void add(Collection c, String itemId) {
    if (c.items.contains(itemId)) return;
    c.items.add(itemId);
    _changed(c);
  }

  void take(Collection c, String itemId) {
    if (c.items.remove(itemId)) _changed(c);
  }

  /// A book or a note was removed from the library: out of every collection.
  void forget(String itemId) {
    for (final c in _all.values) {
      if (c.items.contains(itemId)) take(c, itemId);
    }
  }

  void _changed(Collection c) {
    c.changed = DateTime.now();
    notifyListeners();
    _save();
  }

  void _save() {
    _file?.writeAsString(jsonEncode(_toJson()));
  }

  Map<String, Object?> _toJson() => {
    'collections': [for (final c in _all.values) c.toJson()],
  };

  /// The file's bytes, for the account.
  Uint8List bytes() => utf8.encode(jsonEncode(_toJson()));

  /// Takes the collections of another version (the account's): each one by
  /// the later change, a removed one staying removed.
  Future<void> applyBytes(Uint8List b) async {
    _merge(utf8.decode(b), save: true);
  }

  void _merge(String text, {required bool save}) {
    final j = jsonDecode(text);
    final list = j is Map ? j['collections'] : null;
    if (list is! List) return;
    var any = false;
    for (final raw in list) {
      final theirs = Collection.fromJson(raw);
      if (theirs == null) continue;
      final mine = _all[theirs.id];
      if (mine == null || theirs.changed.isAfter(mine.changed)) {
        _all[theirs.id] = theirs;
        any = true;
      }
    }
    if (any) {
      notifyListeners();
      if (save) _save();
    }
  }
}
