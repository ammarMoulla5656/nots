import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'catalog_store.dart';
import 'own_covers.dart';

/// Covers kept on the device: each one is fetched once, then works offline.
/// A cover's name changes with its content, so a kept file is never stale.
class CoverCache {
  static final _pending = <String, Future<File?>>{};

  /// Where covers are kept and how they are fetched; tests may replace them.
  static Future<Directory> Function() dirProvider = () async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'covers'),
  );
  static http.Client client = http.Client();
  static int _running = 0;
  static final _waiting = <Completer<void>>[];
  static const _maxAtOnce = 4;

  /// Covers already found on the device: a cover scrolled back into view
  /// shows at once, without asking the disk again.
  static final _known = <String, File>{};

  /// The kept file of [cover] when it is already known, else null.
  static File? known(String cover) => _known[cover];

  static Future<File?> get(String cover) =>
      _pending[cover] ??= _fetch(cover).whenComplete(() {
        // In a block on purpose: remove() gives back this very future, and
        // whenComplete would wait for it, that is, for itself, for ever.
        _pending.remove(cover);
      });

  static Future<File?> _fetch(String cover) async {
    final dir = await dirProvider();
    final file = File(p.join(dir.path, p.basename(cover)));
    if (await file.exists()) return _known[cover] = file;
    if (_running >= _maxAtOnce) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final r = await client
          .get(CatalogStore.urlOf(cover))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      await dir.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(r.bodyBytes, flush: true);
      return _known[cover] = await tmp.rename(file.path);
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
  const CoverImage(
    this.cover, {
    super.key,
    this.width = 56,
    this.height = 78,
    this.ownId,
    this.clip = true,
  });

  /// Round its corners itself; false when the one showing it already does.
  final bool clip;

  /// Path of the cover on the server; empty when the book has none.
  final String cover;

  /// The book whose cover, when [cover] is empty, is the picture of its
  /// first page made on the device ([OwnCovers]).
  final String? ownId;
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
    _file = CoverCache.known(widget.cover);
    if (_file == null) _load();
  }

  @override
  void didUpdateWidget(CoverImage old) {
    super.didUpdateWidget(old);
    if (old.cover != widget.cover) {
      _file = CoverCache.known(widget.cover);
      if (_file == null) _load();
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
    final own = widget.ownId;
    if (widget.cover.isEmpty && own != null) {
      return ListenableBuilder(
        listenable: OwnCovers.instance,
        builder: (context, _) =>
            _picture(context, OwnCovers.instance.fileOf(own)),
      );
    }
    return _picture(context, _file);
  }

  Widget _picture(BuildContext context, File? file) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final picture = SizedBox(
      width: widget.width,
      height: widget.height,
      child: file != null
          ? ColoredBox(
              // Seen only while the picture is being decoded.
              color: scheme.secondaryContainer,
              child: Image.file(
                file,
                fit: BoxFit.cover,
                // Decoded at the size shown, not the file's own.
                cacheWidth: (widget.width * dpr).round(),
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _plain(scheme),
              ),
            )
          : _plain(scheme),
    );
    if (!widget.clip) return picture;
    return ClipRRect(borderRadius: BorderRadius.circular(6), child: picture);
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
