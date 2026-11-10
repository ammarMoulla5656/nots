import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../stats/usage.dart';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../library/library_store.dart';
import '../library/package_import.dart';
import 'catalog_models.dart';
import 'catalog_store.dart';

enum DownloadState { waiting, running, failed }

/// One file on its way to the library.
class DownloadTask {
  DownloadTask(this.book, this.part);

  final CatalogBook book;
  final CatalogPart part;
  DownloadState state = DownloadState.waiting;
  int received = 0;
  String? error;

  /// Closing it stops the transfer.
  http.Client? client;
  bool cancelled = false;

  double? get progress =>
      part.size > 0 ? (received / part.size).clamp(0.0, 1.0) : null;

  String get key => DownloadManager.keyOf(book.id, part.number);
}

/// Downloads books into the library, one after another. An interrupted
/// download continues from where it stopped, and a file only enters the
/// library once its size and hash match the catalogue.
class DownloadManager extends ChangeNotifier {
  DownloadManager(
    this._library,
    this._root, {
    http.Client Function()? clientFactory,
    this.afterImport,
  }) : _newClient = clientFactory ?? http.Client.new;

  final LibraryStore _library;
  final Directory _root;
  final http.Client Function() _newClient;

  /// Runs when a book entered the library: its writing is brought from the
  /// user's Drive here.
  Future<void> Function(BookEntry entry)? afterImport;

  final _tasks = <String, DownloadTask>{};
  bool _pumping = false;

  static String keyOf(String bookId, int part) => '$bookId#$part';

  DownloadTask? taskOf(String bookId, int part) => _tasks[keyOf(bookId, part)];

  bool get active => _tasks.values.any((t) => t.state != DownloadState.failed);

  /// Adds [part] to the queue, unless it is in the library or queued already.
  void enqueue(CatalogBook book, CatalogPart part) {
    final key = DownloadManager.keyOf(book.id, part.number);
    final old = _tasks[key];
    final have = _library.byCatalog(book.id, part.number);
    if (have != null && _library.isOnDevice(have)) return;
    if (old != null && old.state != DownloadState.failed) return;
    Usage.instance.catalog(book.id, 'dl');
    _tasks[key] = DownloadTask(book, part);
    notifyListeners();
    unawaited(_pump());
  }

  void enqueueAll(CatalogBook book) {
    for (final part in book.parts) {
      enqueue(book, part);
    }
  }

  /// Stops [t] and forgets it. What was received stays, so downloading the
  /// same file again continues from there.
  void cancel(DownloadTask t) {
    t.cancelled = true;
    t.client?.close();
    _tasks.remove(t.key);
    notifyListeners();
  }

  /// Stops everything: the library is about to be emptied.
  void cancelAll() {
    for (final t in _tasks.values.toList()) {
      cancel(t);
    }
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final next = _tasks.values
            .where((t) => t.state == DownloadState.waiting)
            .firstOrNull;
        if (next == null) return;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(DownloadTask t) async {
    t.state = DownloadState.running;
    notifyListeners();
    final client = t.client = _newClient();
    try {
      final file = await _transfer(t, client);
      if (t.cancelled) return;
      await _verify(t, file);
      await _import(t, file);
      _tasks.remove(t.key);
    } catch (e) {
      if (t.cancelled) return;
      t
        ..state = DownloadState.failed
        ..error = _describe(e);
    } finally {
      client.close();
      t.client = null;
      notifyListeners();
    }
  }

  String _describe(Object e) => switch (e) {
    SocketException() ||
    http.ClientException() ||
    TimeoutException() => 'انقطع الاتصال. أعد المحاولة ليكمل من حيث توقف.',
    _ => '$e',
  };

  File _partial(DownloadTask t) => File(
    p.join(
      _root.path,
      'downloads',
      // Named by the content's hash: a replaced file on the server never
      // continues a transfer of the old one.
      '${t.book.id}-${t.part.number}-${t.part.sha256.isEmpty ? 'x' : t.part.sha256.substring(0, 12)}.part',
    ),
  );

  Future<File> _transfer(DownloadTask t, http.Client client) async {
    final file = _partial(t);
    await file.parent.create(recursive: true);
    var have = await file.exists() ? await file.length() : 0;
    if (t.part.size > 0 && have >= t.part.size) {
      t.received = have;
      return file; // complete already: the check below decides
    }
    final request = http.Request('GET', CatalogStore.urlOf(t.part.file));
    if (have > 0) request.headers['Range'] = 'bytes=$have-';
    final r = await client.send(request).timeout(const Duration(seconds: 30));
    if (r.statusCode == 200) {
      have = 0; // the server sends the whole file
    } else if (r.statusCode != 206) {
      await r.stream.drain<void>();
      throw 'لم يوجد الملف على السيرفر (${r.statusCode}).';
    }
    t.received = have;
    final sink = file.openWrite(
      mode: have > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );
    var lastShown = DateTime.now();
    try {
      await for (final chunk in r.stream.timeout(const Duration(seconds: 45))) {
        sink.add(chunk);
        t.received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastShown).inMilliseconds > 200) {
          lastShown = now;
          notifyListeners();
        }
      }
    } finally {
      await sink.close();
    }
    return file;
  }

  Future<void> _verify(DownloadTask t, File file) async {
    final size = await file.length();
    if (t.part.size > 0 && size != t.part.size) {
      if (size > t.part.size) await file.delete();
      throw 'الملف ناقص ($size من ${t.part.size}). أعد المحاولة.';
    }
    if (t.part.sha256.isEmpty) return;
    final hash = await sha256.bind(file.openRead()).first;
    if (hash.toString() != t.part.sha256) {
      await file.delete();
      throw 'الملف تالف، حُذف. أعد التحميل.';
    }
  }

  Future<void> _import(DownloadTask t, File file) async {
    final title = t.book.titleOf(t.part);
    final BookEntry entry;
    if (t.part.format == 'nots') {
      entry = await importPackage(
        _library,
        await file.readAsBytes(),
        // The user's own writing is never replaced by a published file.
        confirmReplace: (_) async => false,
      );
    } else {
      entry = await _library.importPdf(
        file.path,
        title: title,
        fileName: p.basename(t.part.file),
      );
    }
    await _library.linkCatalog(
      entry,
      catalogId: t.book.id,
      part: t.part.number,
      title: title,
      author: t.book.author,
      subject: t.book.subject,
      cover: t.book.cover,
    );
    await file.delete();
    await afterImport?.call(entry);
  }
}
