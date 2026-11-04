import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'catalog_store.dart';

/// Covers kept on the device: each one is fetched once, then works offline.
/// A cover's name changes with its content, so a kept file is never stale.
class CoverCache {
  static final _pending = <String, Future<File?>>{};
  static final _client = http.Client();
  static int _running = 0;
  static final _waiting = <Completer<void>>[];
  static const _maxAtOnce = 4;

  static Future<File?> get(String cover) =>
      _pending[cover] ??= _fetch(cover).whenComplete(
        () => _pending.remove(cover),
      );

  static Future<File?> _fetch(String cover) async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'covers'),
    );
    final file = File(p.join(dir.path, p.basename(cover)));
    if (await file.exists()) return file;
    if (_running >= _maxAtOnce) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final r = await _client
          .get(CatalogStore.urlOf(cover))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      await dir.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(r.bodyBytes, flush: true);
      return await tmp.rename(file.path);
    } on Exception {
      return null; // no connection: the plain cover stays
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

/// The cover of a book, or a plain one while there is none.
class CoverImage extends StatefulWidget {
  const CoverImage(this.cover, {super.key, this.width = 56, this.height = 78});

  /// Path of the cover on the server; empty when the book has none.
  final String cover;
  final double width;
  final double height;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage old) {
    super.didUpdateWidget(old);
    if (old.cover != widget.cover) {
      _file = null;
      _load();
    }
  }

  Future<void> _load() async {
    final wanted = widget.cover;
    if (wanted.isEmpty) return;
    final f = await CoverCache.get(wanted);
    if (mounted && wanted == widget.cover) setState(() => _file = f);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = _file;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: file != null
            ? Image.file(
                file,
                fit: BoxFit.cover,
                cacheWidth: (widget.width * dpr).round(),
                errorBuilder: (_, _, _) => _plain(scheme),
              )
            : _plain(scheme),
      ),
    );
  }

  Widget _plain(ColorScheme scheme) => ColoredBox(
    color: scheme.secondaryContainer,
    child: Icon(
      Icons.menu_book_outlined,
      color: scheme.onSecondaryContainer,
      size: widget.width * 0.5,
    ),
  );
}
