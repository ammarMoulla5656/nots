import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/catalog/catalog_store.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/notes/note_pdf.dart';
import 'package:nots/notes/paper.dart';
import 'package:nots/reader/tool_layout.dart';
import 'package:nots/sync/drive_client.dart';
import 'package:path/path.dart' as p;

void main() {
  group('paper', () {
    test('a paper is kept as text and read back', () {
      const s = PaperStyle(
        kind: PaperKind.grid,
        paper: 0xFFFFF4CC,
        line: 0xFFC8372D,
      );
      expect(PaperStyle.parse(s.encode()), s);
    });

    test('text that is not a paper is plain white paper', () {
      expect(PaperStyle.parse(''), const PaperStyle());
      expect(PaperStyle.parse('lined|zz|1'), const PaperStyle());
      expect(PaperStyle.parse('other|ffffffff|ffffffff'), const PaperStyle());
    });

    test('blank paper has no lines; lined and squared have', () {
      expect(paperLines(PaperKind.blank), isEmpty);
      expect(paperLines(PaperKind.lined).length, greaterThan(20));
      expect(paperLines(PaperKind.grid).length, greaterThan(50));
    });

    test('the PDF is made of lines, not a picture, and every page shares one drawing', () {
      final bytes = buildNotePdf(
        style: const PaperStyle(
          kind: PaperKind.lined,
          paper: 0xFFFBF8F1,
          line: 0xFFD6CFBE,
        ),
        pages: 50,
        title: 'ملاحظة',
        stamp: 'x1',
      );
      final text = latin1.decode(bytes);
      expect(text.startsWith('%PDF-1.4'), isTrue);
      expect(text, contains('/Count 50'));
      expect(text, isNot(contains('/Image')));
      // One drawing stream, however many pages.
      expect('stream'.allMatches(text).length, 2 * 1);
      expect(bytes.length, lessThan(20 * 1024));
    });

    test('the cross-reference table points at every object', () {
      final bytes = buildNotePdf(
        style: const PaperStyle(kind: PaperKind.grid),
        pages: 5,
        title: 't',
        stamp: 'x2',
      );
      final text = latin1.decode(bytes);
      final start = int.parse(
        RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!,
      );
      expect(text.substring(start).startsWith('xref'), isTrue);
      final rows = RegExp(r'(\d{10}) 00000 n').allMatches(text).toList();
      expect(rows.length, 4 + 5);
      for (var i = 0; i < rows.length; i++) {
        final at = int.parse(rows[i].group(1)!);
        expect(text.substring(at).startsWith('${i + 1} 0 obj'), isTrue);
      }
    });

    test('two notes on the same paper are different files', () async {
      final root = await Directory.systemTemp.createTemp('nots_note_');
      addTearDown(() => root.delete(recursive: true));
      final lib = await LibraryStore.openAt(root);
      final a = await _note(lib, root, 'a');
      final b = await _note(lib, root, 'b');
      expect(a.id, isNot(b.id));
      expect(a.isNote, isTrue);
      expect(PaperStyle.parse(a.author).kind, PaperKind.lined);
    });
  });

  test('the free space is what is left of the limit', () {
    expect(const DriveQuota(3, 10).left, 7);
    expect(const DriveQuota(12, 10).left, 0);
    expect(const DriveQuota(3, null).left, isNull);
  });

  group('the order of Masdar', () {
    test('categories follow it, and names that contain one count as it', () {
      expect(masdarRank('الحديث الشريف'), lessThan(masdarRank('الفقه')));
      expect(masdarRank('الفقه'), lessThan(masdarRank('أصول الفقه')));
      expect(masdarRank('كتب الفقه'), masdarRank('الفقه'));
      expect(masdarRank('أصول الفقه'), masdarRank('أصول الفقه'));
      expect(masdarRank('شيء آخر'), masdarOrder.length);
    });
  });

  group('the tools', () {
    test('every tool is in the bar or the box, once', () {
      final l = ToolLayout();
      expect(
        {...l.bar, ...l.box}.length,
        ReaderTool.values.where((t) => t.offered).length,
      );
      expect(
        l.bar.length + l.box.length,
        ReaderTool.values.where((t) => t.offered).length,
      );
    });

    test('a tool moves between the bar and the box, and back', () {
      final l = ToolLayout();
      l.place(ReaderTool.laser, bar: true, index: 1);
      expect(l.bar[1], ReaderTool.laser);
      expect(l.box.contains(ReaderTool.laser), isFalse);
      l.flip(ReaderTool.laser);
      expect(l.inBar(ReaderTool.laser), isFalse);
      l.reset();
      expect(l.bar, ToolLayout.defaultBar);
      expect(l.box, ToolLayout.defaultBox);
    });

    test(
      'the arrangement is kept, and a tool added later lands in the box',
      () async {
        final dir = await Directory.systemTemp.createTemp('nots_tools_');
        addTearDown(() => dir.delete(recursive: true));
        ToolLayout.dirProvider = () async => dir;
        final a = ToolLayout();
        await a.load();
        a.place(ReaderTool.laser, bar: true);
        a.place(ReaderTool.eraser, bar: false);
        final b = ToolLayout();
        await b.load();
        expect(b.bar.last, ReaderTool.laser);
        expect(b.inBar(ReaderTool.eraser), isFalse);
        // A file from an older version that did not know every tool.
        await File(p.join(dir.path, 'tools.json')).writeAsString(
          jsonEncode({
            'bar': ['pen', 'hand'],
            'box': ['shape'],
          }),
        );
        final c = ToolLayout();
        await c.load();
        expect(c.bar, [ReaderTool.pen, ReaderTool.hand]);
        expect(
          c.box.length + c.bar.length,
          ReaderTool.values.where((t) => t.offered).length,
        );
        expect(c.box.first, ReaderTool.shape);
      },
    );
  });
}

Future<BookEntry> _note(LibraryStore lib, Directory root, String name) async {
  final bytes = buildNotePdf(
    style: const PaperStyle(kind: PaperKind.lined),
    pages: 3,
    title: name,
    stamp: '${DateTime.now().microsecondsSinceEpoch}$name',
  );
  final f = File(p.join(root.path, '$name.pdf'))..writeAsBytesSync(bytes);
  final e = await lib.importPdf(f.path, title: name);
  await lib.markNote(
    e,
    template: const PaperStyle(kind: PaperKind.lined).encode(),
  );
  return e;
}
