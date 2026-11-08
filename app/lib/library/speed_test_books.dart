import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../catalog/own_covers.dart';
import '../ink/ink_store.dart';
import '../ink/note_items.dart';
import '../ink/stroke.dart';
import '../notes/note_pdf.dart';
import '../notes/paper.dart';
import '../ui/speed_log.dart';
import '../ui/theme.dart';
import 'library_store.dart';

/// A test library for measuring speed under a heavy load: many long books
/// and notes, written on every page. Kept on this device only: the sync
/// reads them like any book (that is part of what is measured) but never
/// sends them to Drive.
const speedTestSubject = 'تجربة السرعة';
const _prefix = 'speed-test-';

bool isSpeedTest(BookEntry b) => b.isSpeedTest;

/// How many, and how long.
const testBooks = 200, testBookPages = 500;
const testNotes = 100, testNotePages = 300;

/// Strokes written on each test page.
const _strokesPerPage = 15, _pointsPerStroke = 32;

/// One page of writing, the same on every page (only the page differs).
List<Stroke> _pageStrokes(math.Random r, int firstId) {
  final out = <Stroke>[];
  for (var s = 0; s < _strokesPerPage; s++) {
    final highlighter = s % 5 == 4;
    final y0 = 60.0 + s * 48 + r.nextDouble() * 10;
    final x0 = 60.0 + r.nextDouble() * 40;
    out.add(
      Stroke(
        id: firstId + s,
        tool: highlighter ? InkTool.highlighter : InkTool.pen,
        color: highlighter ? 0x66FFD54F : 0xFF0D47A1,
        width: highlighter ? 12 : 1.6,
        points: [
          for (var i = 0; i < _pointsPerStroke; i++)
            StrokePoint(
              x0 + i * 14.0,
              y0 + math.sin(i / 3 + s) * 6,
              0.5,
              i * 12,
            ),
        ],
      ),
    );
  }
  return out;
}

/// A whole document of [pages] written pages, encoded once.
Uint8List _writing(int pages) {
  final r = math.Random(7);
  final strokes = <int, List<Stroke>>{};
  final items = <int, List<NoteItem>>{};
  var id = 1;
  for (var page = 1; page <= pages; page++) {
    strokes[page] = _pageStrokes(r, id);
    id += _strokesPerPage;
    items[page] = [
      NoteItem.mark(
        id: id++,
        lineRects: const [Rect.fromLTWH(70, 400, 300, 14)],
        style: MarkStyle.highlight,
        color: 0xFFFFD54F,
        quote: 'نص معلَّم',
      ),
    ];
  }
  return StrokeCodec.encodeDocument(strokes, id, items: items);
}

const _papers = [
  0xFFFBF8F1,
  0xFFFFF4CC,
  0xFFE3EEFA,
  0xFFE4F3E8,
  0xFFF3E8F5,
  0xFFFFFFFF,
];

class _Made {
  _Made(this.id, this.file, this.size, this.paper);
  final String id;
  final String file;
  final int size;
  final String paper;
}

/// Writes PDFs [from]..[to] (exclusive) of one kind into [booksDir], each
/// with [writing] as its ink in [inkDir]. Runs away from the screen.
Future<List<_Made>> _makeBatch({
  required String booksDir,
  required String inkDir,
  required bool notes,
  required int from,
  required int to,
  required int pages,
  required Uint8List writing,
}) => Isolate.run(() async {
  final out = <_Made>[];
  for (var i = from; i < to; i++) {
    final style = PaperStyle(
      kind: notes ? PaperKind.values[i % 3] : PaperKind.lined,
      paper: _papers[i % _papers.length],
      line: 0xFFB9C7DA,
    );
    final bytes = buildNotePdf(
      style: style,
      pages: pages,
      title: notes ? 'ملاحظة تجريبية ${i + 1}' : 'كتاب تجريبي ${i + 1}',
      stamp:
          '$_prefix${notes ? 'n' : 'b'}$i-${DateTime.now().microsecondsSinceEpoch}',
    );
    final tmp = File(p.join(booksDir, '$_prefix$i.tmp'));
    await tmp.writeAsBytes(bytes, flush: true);
    final id = await fingerprintFile(tmp);
    await tmp.rename(p.join(booksDir, '$id.pdf'));
    await File(p.join(inkDir, '$id.nots')).writeAsBytes(writing, flush: true);
    out.add(
      _Made(
        id,
        '$_prefix${notes ? 'note' : 'book'}-$i.pdf',
        bytes.length,
        style.encode(),
      ),
    );
  }
  return out;
});

/// Free space where the library is, in bytes, or null when unknown.
Future<int?> freeSpace(Directory dir) async {
  try {
    final r = await Process.run('df', ['-k', dir.path]);
    final lines = (r.stdout as String).trim().split('\n');
    final cols = lines.last.trim().split(RegExp(r'\s+'));
    // Filesystem 1K-blocks Used Available ...
    return int.parse(cols[3]) * 1024;
  } on Object {
    return null;
  }
}

/// Bytes the test library takes, roughly.
int estimatedSize() {
  const perPage = _strokesPerPage * (_pointsPerStroke * 7 + 12) + 60;
  return testBooks * (testBookPages * perPage + testBookPages * 110) +
      testNotes * (testNotePages * perPage + testNotePages * 110);
}

/// Adds the test library; [progress] says how far it is.
Future<void> addSpeedTestLibrary(
  LibraryStore library,
  ValueNotifier<String?> progress, {
  int books = testBooks,
  int bookPages = testBookPages,
  int notes = testNotes,
  int notePages = testNotePages,
}) async {
  final log = SpeedLog.instance;
  final sw = Stopwatch()..start();
  progress.value = 'تحضير الكتابة…';
  final bookInk = await Isolate.run(() => _writing(bookPages));
  final noteInk = await Isolate.run(() => _writing(notePages));
  final booksDir = p.join(library.root.path, 'books');
  final inkDir = (await InkStore.dirProvider()).path;
  await Directory(inkDir).create(recursive: true);
  final entries = <BookEntry>[];
  final now = DateTime.now();
  Future<void> run(bool notes, int count, int pages, Uint8List ink) async {
    const batch = 10;
    for (var from = 0; from < count; from += batch) {
      progress.value = notes
          ? 'ملاحظات ${from + 1} من $count…'
          : 'كتب ${from + 1} من $count…';
      final made = await _makeBatch(
        booksDir: booksDir,
        inkDir: inkDir,
        notes: notes,
        from: from,
        to: math.min(count, from + batch),
        pages: pages,
        writing: ink,
      );
      for (final m in made) {
        final n = entries.length;
        entries.add(
          BookEntry(
            id: m.id,
            title: notes
                ? 'ملاحظة تجريبية ${n - books + 1}'
                : 'كتاب تجريبي ${n + 1}',
            fileName: m.file,
            size: m.size,
            added: now.subtract(Duration(minutes: n)),
            lastOpened: now.subtract(Duration(minutes: n)),
            subject: notes ? noteSubject : speedTestSubject,
            author: notes ? m.paper : 'مؤلف تجريبي',
          ),
        );
      }
    }
  }

  await run(false, books, bookPages, bookInk);
  await run(true, notes, notePages, noteInk);
  progress.value = 'حفظ المكتبة…';
  await library.addMany(entries);
  log.took(
    'test library added',
    sw.elapsedMilliseconds,
    '${entries.length} items, ink ${bookInk.length ~/ 1024}KB/book ${noteInk.length ~/ 1024}KB/note',
  );
  progress.value = null;
}

Future<void> removeSpeedTestLibrary(LibraryStore library) async {
  final gone = await library.removeWhere(isSpeedTest, deleteWriting: true);
  for (final id in gone) {
    await OwnCovers.instance.remove(id);
  }
  SpeedLog.instance.note('test library removed: ${gone.length}');
}

/// The "speed measuring" part of the account sheet.
class SpeedPanel extends StatefulWidget {
  const SpeedPanel({super.key, required this.library});

  final LibraryStore library;

  @override
  State<SpeedPanel> createState() => _SpeedPanelState();
}

class _SpeedPanelState extends State<SpeedPanel> {
  final _progress = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _say(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _share() async {
    final log = SpeedLog.instance;
    await log.flushNow();
    final f = log.file;
    if (f == null || !await f.exists()) {
      _say('لا يوجد سجل بعد. شغّل «قياس السرعة» واستعمل التطبيق قليلاً.');
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(f.path, name: 'speed.log', mimeType: 'text/plain')],
      ),
    );
  }

  Future<void> _add() async {
    final need = estimatedSize();
    final free = await freeSpace(widget.library.root);
    String mb(int b) => '${(b / (1024 * 1024)).round()} م.ب';
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إضافة المكتبة التجريبية؟'),
        content: Text(
          '$testBooks كتاباً في كل منها $testBookPages صفحة، و$testNotes ملاحظة في كل منها $testNotePages صفحة، وعلى كل الصفحات كتابة.\n\n'
          'تأخذ تقريباً ${mb(need)}${free == null ? '' : '، والمساحة الفارغة ${mb(free)}'}.\n'
          'تبقى على هذا الجهاز فقط ولا تُرفع إلى درايف، وتُحذف بزر واحد.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: free != null && free < need * 1.3
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await addSpeedTestLibrary(widget.library, _progress);
      if (mounted) _say('أُضيفت المكتبة التجريبية.');
    } on Object catch (e) {
      _progress.value = null;
      if (mounted) _say('تعذّرت الإضافة: $e');
    }
  }

  Future<void> _remove() async {
    _progress.value = 'حذف…';
    await removeSpeedTestLibrary(widget.library);
    _progress.value = null;
    if (mounted) _say('حُذفت المكتبة التجريبية.');
  }

  @override
  Widget build(BuildContext context) {
    final log = SpeedLog.instance;
    final tests = widget.library.books.where(isSpeedTest).length;
    return ListenableBuilder(
      listenable: Listenable.merge([log, _progress]),
      builder: (context, _) {
        final busy = _progress.value != null;
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.speed),
                title: const Text('قياس السرعة'),
                subtitle: const Text(
                  'يعرض زمن رسم كل إطار، ويسجّل أزمنة العمليات في سجل السرعة',
                ),
                value: log.enabled,
                onChanged: (v) => log.setEnabled(v),
              ),
              if (log.enabled) ...[
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: const Text('مشاركة سجل السرعة'),
                  onTap: _share,
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('بدء سجل جديد'),
                  onTap: () async {
                    await log.clear();
                    _say('بدأ سجل جديد.');
                  },
                ),
                const Divider(),
                if (busy)
                  ListTile(
                    leading: const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    title: Text(_progress.value!),
                  )
                else if (tests == 0)
                  ListTile(
                    leading: const Icon(Icons.library_add_outlined),
                    title: const Text('إضافة مكتبة تجريبية'),
                    subtitle: Text(
                      '$testBooks كتاب × $testBookPages صفحة، و$testNotes ملاحظة × $testNotePages صفحة، كلها مكتوب عليها',
                    ),
                    onTap: _add,
                  )
                else
                  ListTile(
                    leading: Icon(Icons.delete_outline, color: Brand.red),
                    title: Text(
                      'حذف المكتبة التجريبية ($tests)',
                      style: TextStyle(color: Brand.red),
                    ),
                    onTap: _remove,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
