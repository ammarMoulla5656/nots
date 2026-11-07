import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'note_items.dart';

/// A picture ready to put on a page: the JPEG as base64, and its size.
typedef PreparedImage = ({String data, int width, int height});

/// Reads [bytes] (any common picture format, a phone photo included),
/// turns it upright, shrinks it so its longer side is at most [maxSide]
/// pixels, and keeps it as a JPEG. Done off the main thread. Returns null
/// when the bytes are not a picture.
Future<PreparedImage?> prepareImage(Uint8List bytes, {int maxSide = 1400}) =>
    Isolate.run(() {
      var image = img.decodeImage(bytes);
      if (image == null) return null;
      image = img.bakeOrientation(image);
      final longer = image.width > image.height ? image.width : image.height;
      if (longer > maxSide) {
        image = image.width >= image.height
            ? img.copyResize(image, width: maxSide)
            : img.copyResize(image, height: maxSide);
      }
      final jpg = img.encodeJpg(image, quality: 82);
      return (
        data: base64Encode(jpg),
        width: image.width,
        height: image.height,
      );
    });

/// The pictures placed on pages, decoded once and kept. The pages paint
/// what is ready; a picture still being read draws as an empty frame and
/// the page is told to paint again when it arrives.
class ImageItems extends ChangeNotifier {
  ImageItems._();

  static final instance = ImageItems._();

  final _ready = <String, ui.Image>{};
  final _loading = <String, Future<ui.Image?>>{};

  /// The decoded picture, or null while it is being read.
  ui.Image? of(String data) {
    final image = _ready[data];
    if (image != null) return image;
    _load(data);
    return null;
  }

  Future<ui.Image?> _load(String data) => _loading[data] ??= () async {
    try {
      final codec = await ui.instantiateImageCodec(base64Decode(data));
      final frame = await codec.getNextFrame();
      codec.dispose();
      _ready[data] = frame.image;
      notifyListeners();
      return frame.image;
    } on Object {
      return null; // a damaged picture stays an empty frame
    }
  }();

  /// Waits until every picture among [items] is decoded (for exporting).
  Future<void> preload(Iterable<NoteItem> items) async {
    for (final it in items) {
      if (it.kind == ItemKind.image) await _load(it.text);
    }
  }
}

/// A new picture item at [center] (PDF points), as wide as [width] points
/// unless the page is narrower, keeping the picture's proportions.
NoteItem pictureItem({
  required int id,
  required PreparedImage image,
  required ui.Offset center,
  required double width,
}) {
  final w = width;
  final h = w * image.height / image.width;
  return NoteItem(
    id: id,
    kind: ItemKind.image,
    x: center.dx - w / 2,
    y: center.dy - h / 2,
    w: w,
    h: h,
    text: image.data,
  );
}
