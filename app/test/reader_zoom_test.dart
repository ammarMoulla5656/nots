import 'package:flutter_test/flutter_test.dart';
import 'package:nots/reader/reader_zoom.dart';

void main() {
  test('zooming out stops a little past one whole page', () {
    // Landscape: the whole page needs a smaller scale than the width.
    expect(readerMinScale(2.0, 0.8), closeTo(0.8 * ReaderZoom.room, 1e-9));
    // Portrait: the width is what limits.
    expect(readerMinScale(0.7, 0.9), closeTo(0.7 * ReaderZoom.room, 1e-9));
    // Before the page size is known.
    expect(readerMinScale(1.2, null), closeTo(1.2 * ReaderZoom.room, 1e-9));
  });
}
