import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/export/doc_export.dart';
import 'package:xml/xml.dart';

const _ops = [
  {'insert': 'كتاب الطهارة'},
  {
    'insert': '\n',
    'attributes': {'header': 1},
  },
  {
    'insert': 'نص ',
    'attributes': {'font': 'Amiri', 'size': '18'},
  },
  {
    'insert': 'غامق وملوّن',
    'attributes': {
      'bold': true,
      'color': '#ff1c4f92',
      'background': '#ffffd54f',
    },
  },
  {
    'insert': ' & <رمز>\n',
    'attributes': {'align': 'center'},
  },
  {'insert': 'عنصر في قائمة'},
  {
    'insert': '\n',
    'attributes': {'list': 'bullet'},
  },
  {'insert': 'أحكام المياه'},
  {
    'insert': '\n',
    'attributes': {'header': 2},
  },
];

void main() {
  test('the docx is a valid package with the text, looks and contents', () {
    final bytes = writeDocx(_ops, title: 'ملف نصي');
    final zip = ZipDecoder().decodeBytes(bytes);
    for (final part in [
      '[Content_Types].xml',
      '_rels/.rels',
      'word/document.xml',
      'word/styles.xml',
      'word/_rels/document.xml.rels',
    ]) {
      final file = zip.findFile(part);
      expect(file, isNotNull, reason: part);
      // Word refuses a part that is not well-formed XML.
      XmlDocument.parse(utf8.decode(file!.content));
    }
    final doc = utf8.decode(zip.findFile('word/document.xml')!.content);
    expect(doc, contains('كتاب الطهارة'));
    expect(doc, contains('w:pStyle w:val="Heading1"'));
    expect(doc, contains('w:pStyle w:val="Heading2"'));
    expect(doc, contains('<w:b/>'));
    expect(doc, contains('w:color w:val="1C4F92"'));
    expect(doc, contains('w:fill="FFD54F"'));
    expect(doc, contains('w:rFonts w:ascii="Amiri"'));
    expect(doc, contains('w:val="36"'), reason: '18 pt is 36 half-points');
    expect(doc, contains('w:jc w:val="center"'));
    expect(
      doc,
      contains(r'TOC \o "1-3"'),
      reason: 'a contents from the headings',
    );
    expect(doc, contains('&amp; &lt;رمز&gt;'), reason: 'text is escaped');
    expect(doc, contains('<w:bidi/>'), reason: 'right to left');
  });

  test('no contents field when there are no headings', () {
    final bytes = writeDocx([
      {'insert': 'سطر واحد\n'},
    ], title: 'x');
    final doc = utf8.decode(
      ZipDecoder().decodeBytes(bytes).findFile('word/document.xml')!.content,
    );
    expect(doc, isNot(contains('TOC ')));
  });

  test('the RTF has the text as Unicode escapes, fonts, colours and size', () {
    final rtf = latin1.decode(writeRtf(_ops, title: 'ملف'));
    expect(rtf, startsWith(r'{\rtf1'));
    // Pure ASCII: every Arabic letter is an escape (U+0643 is 1603).
    expect(rtf.codeUnits.every((c) => c < 128), isTrue);
    final bs = String.fromCharCode(92);
    expect(rtf, contains('${bs}u1603?'));
    expect(rtf, contains('Amiri'));
    expect(rtf, contains(r'\b\cf1'), reason: 'bold, then its colour');
    expect(rtf, contains(r'\red28\green79\blue146;'));
    expect(rtf, contains(r'\fs36'));
    expect(rtf, contains(r'\outlinelevel0'));
    expect(rtf, contains(r'\qc'));
    expect(rtf, contains(r'\rtlpar'));
    expect(rtf.endsWith('}'), isTrue);
  });
}
