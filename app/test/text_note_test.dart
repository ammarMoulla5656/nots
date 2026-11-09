import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/export/share_file.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/library/package_import.dart';
import 'package:nots/notes/text_note.dart';
import 'package:nots/sync/sync_engine.dart';
import 'package:path/path.dart' as p;

const _ops = [
  {'insert': 'كتاب الطهارة'},
  {
    'insert': '\n',
    'attributes': {'header': 1},
  },
  {'insert': 'نص عادي\n'},
  {'insert': 'أحكام المياه'},
  {
    'insert': '\n',
    'attributes': {'header': 2},
  },
  {'insert': 'سطر آخر\n'},
];

Future<LibraryStore> _library() async {
  final root = await Directory.systemTemp.createTemp('textnote');
  TextNoteStore.dirProvider = () async => Directory(p.join(root.path, 'docs'));
  InkStore.dirProvider = () async => Directory(p.join(root.path, 'ink'));
  return LibraryStore.openAt(root);
}

Uint8List _doc(List<dynamic> ops) =>
    Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'ops': ops})));

void main() {
  test('a text note is made, kept and read back', () async {
    final lib = await _library();
    final note = await createTextNote(lib, title: 'دروس الفقه');
    expect(isTextNote(note), isTrue);
    expect(note.isNote, isTrue);
    expect(lib.isOnDevice(note), isTrue, reason: 'it carries a small PDF');
    expect(textNoteHasLines(note), isTrue);

    await TextNoteStore.write(note.id, _ops);
    final back = await TextNoteStore.read(note.id);
    expect(jsonEncode(back), jsonEncode(_ops));
    expect(await TextNoteStore.preview(note.id), contains('كتاب الطهارة'));

    // An ordinary paper note is not a text note.
    expect(
      isTextNote(
        BookEntry(
          id: 'x',
          title: 't',
          fileName: 'f',
          size: 1,
          added: DateTime.now(),
          lastOpened: DateTime.now(),
          subject: noteSubject,
          author: 'lined|ffffffff|ffb9c7da',
        ),
      ),
      isFalse,
    );
  });

  test('the contents come from the headings, in order', () {
    final heads = headingsOf(Document.fromJson(_ops));
    expect(heads.map((h) => (h.title, h.level)), [
      ('كتاب الطهارة', 1),
      ('أحكام المياه', 2),
    ]);
    expect(heads.first.offset, 0);
    expect(heads.last.offset, greaterThan(heads.first.offset));
  });

  test('the text goes through the account and comes back whole', () {
    final w = WorkBundle(doc: _doc(_ops));
    expect(w.isEmpty, isFalse, reason: 'typed text is work');
    final back = WorkBundle.decode(w.encode());
    expect(utf8.decode(back.doc!), utf8.decode(w.doc!));
    // A text with nothing typed is not work.
    expect(WorkBundle(doc: _doc(TextNoteStore.emptyOps())).isEmpty, isTrue);
    // The text changes the fingerprint; a book without one keeps its own.
    expect(w.hash, isNot(const WorkBundle().hash));
    expect(const WorkBundle(ink: null).hash, const WorkBundle().hash);
  });

  test('two devices wrote: the later text stays whole, the other is kept', () {
    final mine = _doc([
      {'insert': 'كتبتُ هنا\n'},
    ]);
    final theirs = _doc([
      {'insert': 'كتبتُ هناك\n'},
    ]);
    final merged =
        (jsonDecode(utf8.decode(TextNoteStore.mergeBoth(theirs, mine)))
                as Map)['ops']
            as List;
    final texts = [for (final o in merged) (o as Map)['insert'] as String];
    // The later text comes first and whole; the other follows, after a mark.
    expect(texts.first, contains('هناك'));
    expect(texts.where((t) => t.contains('الجهاز الآخر')), isNotEmpty);
    expect(texts.last, contains('كتبتُ هنا'));
    expect(texts.last, isNot(contains('هناك')));
    // The same text on both: unchanged.
    expect(
      utf8.decode(TextNoteStore.mergeBoth(mine, Uint8List.fromList(mine))),
      utf8.decode(mine),
    );
  });

  test(
    'a text note package is told apart and imported with its drawing',
    () async {
      final lib = await _library();
      final bytes = await textNotePackage(
        title: 'ملف مصدَّر',
        ops: _ops,
        ink: InkDocument(),
      );
      expect(isTextNotePackage(bytes), isTrue);
      expect(isTextNotePackage(Uint8List.fromList([1, 2, 3])), isFalse);

      final entry = await importTextNote(lib, bytes);
      expect(isTextNote(entry), isTrue);
      expect(entry.title, 'ملف مصدَّر');
      expect(jsonEncode(await TextNoteStore.read(entry.id)), jsonEncode(_ops));
    },
  );
}
