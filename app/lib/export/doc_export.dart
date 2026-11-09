import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One piece of a paragraph with its look, from the text note's Delta.
class _Run {
  _Run(this.text, this.attrs);

  final String text;
  final Map<String, dynamic> attrs;
}

/// One paragraph (a line of the note): its runs and its own look.
class _Para {
  _Para(this.runs, this.attrs);

  final List<_Run> runs;
  final Map<String, dynamic> attrs;

  bool get isEmpty => runs.every((r) => r.text.isEmpty);
}

/// Splits Delta operations into paragraphs. In a Delta the look of a line
/// (heading, list, alignment) sits on the line break that ends it.
List<_Para> _paragraphs(List<dynamic> ops) {
  final out = <_Para>[];
  var runs = <_Run>[];
  for (final o in ops) {
    if (o is! Map) continue;
    final insert = o['insert'];
    if (insert is! String) continue; // pictures and the like: not text
    final attrs = ((o['attributes'] as Map?) ?? const {})
        .cast<String, dynamic>();
    final parts = insert.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) runs.add(_Run(parts[i], attrs));
      if (i < parts.length - 1) {
        out.add(_Para(runs, attrs));
        runs = <_Run>[];
      }
    }
  }
  if (runs.isNotEmpty) out.add(_Para(runs, const {}));
  return out;
}

String _hex(Object? colour) {
  var c = '$colour'.replaceAll('#', '');
  if (c.length == 8) c = c.substring(2); // ARGB
  return c.length == 6 ? c.toUpperCase() : '000000';
}

/// Size of Quill's named sizes, in points; a number is taken as it is.
double? _size(Object? s) {
  if (s == null) return null;
  final n = double.tryParse('$s');
  if (n != null) return n;
  return switch ('$s') {
    'small' => 10,
    'large' => 18,
    'huge' => 24,
    _ => null,
  };
}

const _headingPt = {1: 22.0, 2: 18.0, 3: 15.0};

String _xml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// The Word file (docx) of a text note: its text with the fonts, sizes,
/// colours, highlights, headings, lists and alignment, written from right
/// to left, with a contents field Word fills from the headings.
Uint8List writeDocx(
  List<dynamic> ops, {
  required String title,
  bool contents = true,
}) {
  final paras = _paragraphs(ops);
  final body = StringBuffer();

  String runXml(_Run r, {double? floor}) {
    final a = r.attrs;
    final props = StringBuffer();
    final font = a['font'];
    if (font != null) {
      props.write('<w:rFonts w:ascii="$font" w:hAnsi="$font" w:cs="$font"/>');
    }
    if (a['bold'] == true) props.write('<w:b/><w:bCs/>');
    if (a['italic'] == true) props.write('<w:i/><w:iCs/>');
    if (a['underline'] == true) props.write('<w:u w:val="single"/>');
    if (a['strike'] == true) props.write('<w:strike/>');
    if (a['color'] != null) {
      props.write('<w:color w:val="${_hex(a['color'])}"/>');
    }
    if (a['background'] != null) {
      props.write(
        '<w:shd w:val="clear" w:color="auto" w:fill="${_hex(a['background'])}"/>',
      );
    }
    final sz = _size(a['size']) ?? floor;
    if (sz != null) {
      final half = (sz * 2).round();
      props.write('<w:sz w:val="$half"/><w:szCs w:val="$half"/>');
    }
    props.write('<w:rtl/>');
    return '<w:r><w:rPr>$props</w:rPr><w:t xml:space="preserve">${_xml(r.text)}</w:t></w:r>';
  }

  var tocDone = false;
  void toc() {
    if (!contents || tocDone) return;
    tocDone = true;
    body.write(
      '<w:p><w:pPr><w:bidi/></w:pPr><w:r><w:rPr><w:b/><w:rtl/></w:rPr><w:t>الفهرس</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:bidi/></w:pPr><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
      '<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>'
      '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
      '<w:r><w:rPr><w:rtl/></w:rPr><w:t>اضغط بالزر الأيمن واختر «تحديث الحقل» ليظهر الفهرس.</w:t></w:r>'
      '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    );
  }

  final hasHeadings = paras.any((p) => p.attrs['header'] is int);
  if (hasHeadings) toc();

  for (final p in paras) {
    final props = StringBuffer('<w:bidi/>');
    final header = p.attrs['header'];
    double? floor;
    if (header is int && header >= 1 && header <= 3) {
      props.write('<w:pStyle w:val="Heading$header"/>');
      floor = _headingPt[header];
    }
    final list = p.attrs['list'];
    if (list != null) {
      props.write('<w:ind w:right="360" w:hanging="360"/>');
    }
    switch (p.attrs['align']) {
      case 'center':
        props.write('<w:jc w:val="center"/>');
      case 'right':
        props.write('<w:jc w:val="left"/>'); // bidi: "left" is the start
      case 'left':
        props.write('<w:jc w:val="right"/>');
      case 'justify':
        props.write('<w:jc w:val="both"/>');
    }
    final bullet = switch (list) {
      'bullet' => '• ',
      'ordered' => '', // numbering is Word's own: plain text here
      'checked' => '☑ ',
      'unchecked' => '☐ ',
      _ => '',
    };
    final runs = [if (bullet.isNotEmpty) _Run(bullet, const {}), ...p.runs];
    body.write(
      '<w:p><w:pPr>$props</w:pPr>${runs.map((r) => runXml(r, floor: floor)).join()}</w:p>',
    );
  }

  const ns =
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';
  final document =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document $ns><w:body>$body'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/>'
      '<w:bidi/></w:sectPr></w:body></w:document>';

  String heading(int n, double pt) =>
      '<w:style w:type="paragraph" w:styleId="Heading$n"><w:name w:val="heading $n"/>'
      '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="${n - 1}"/></w:pPr>'
      '<w:rPr><w:b/><w:bCs/><w:sz w:val="${(pt * 2).round()}"/><w:szCs w:val="${(pt * 2).round()}"/></w:rPr></w:style>';
  final styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles $ns>'
      '<w:docDefaults><w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>'
      '<w:sz w:val="28"/><w:szCs w:val="28"/><w:lang w:bidi="ar-SA"/>'
      '</w:rPr></w:rPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
      '${heading(1, 22)}${heading(2, 18)}${heading(3, 15)}'
      '</w:styles>';

  const contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '</Types>';
  const rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
      '</Relationships>';
  const docRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>';
  final core =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>${_xml(title)}</dc:title></cp:coreProperties>';

  final zip = Archive()
    ..add(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..add(ArchiveFile.string('_rels/.rels', rels))
    ..add(ArchiveFile.string('word/document.xml', document))
    ..add(ArchiveFile.string('word/styles.xml', styles))
    ..add(ArchiveFile.string('word/_rels/document.xml.rels', docRels))
    ..add(ArchiveFile.string('docProps/core.xml', core));
  return Uint8List.fromList(ZipEncoder().encode(zip));
}

/// The RTF file of a text note: the same text with its look, written from
/// right to left. Letters outside ASCII are written as Unicode escapes.
Uint8List writeRtf(List<dynamic> ops, {required String title}) {
  final paras = _paragraphs(ops);
  final fonts = <String>[];
  final colours = <String>[];
  int fontOf(Object? f) {
    final name = '${f ?? 'Arial'}';
    var i = fonts.indexOf(name);
    if (i < 0) {
      fonts.add(name);
      i = fonts.length - 1;
    }
    return i;
  }

  int colourOf(Object? c) {
    final h = _hex(c);
    var i = colours.indexOf(h);
    if (i < 0) {
      colours.add(h);
      i = colours.length - 1;
    }
    return i + 1; // 0 is the automatic colour
  }

  fontOf('Arial');
  String esc(String s) {
    final b = StringBuffer();
    for (final u in s.runes) {
      if (u == 0x5C || u == 0x7B || u == 0x7D) {
        b.write('\\${String.fromCharCode(u)}');
      } else if (u < 0x80) {
        b.writeCharCode(u);
      } else {
        // A signed 16-bit number; beyond it, a pair of surrogates.
        void one(int v) => b.write('\\u${v > 32767 ? v - 65536 : v}?');
        if (u > 0xFFFF) {
          final v = u - 0x10000;
          one(0xD800 + (v >> 10));
          one(0xDC00 + (v & 0x3FF));
        } else {
          one(u);
        }
      }
    }
    return b.toString();
  }

  final body = StringBuffer();
  for (final p in paras) {
    final header = p.attrs['header'];
    final align = switch (p.attrs['align']) {
      'center' => '\\qc',
      'right' => '\\ql', // right to left: the start is the right edge
      'left' => '\\qr',
      'justify' => '\\qj',
      _ => '',
    };
    final level = header is int && header >= 1 && header <= 3
        ? '\\outlinelevel${header - 1}'
        : '';
    body.write('\\pard\\rtlpar$level$align ');
    final list = p.attrs['list'];
    if (list == 'bullet') body.write('\\u8226? ');
    for (final r in p.runs) {
      final a = r.attrs;
      final pt = _size(a['size']) ?? _headingPt[header];
      final on = StringBuffer('\\rtlch');
      on.write('\\f${fontOf(a['font'])}');
      if (a['bold'] == true || header is int) on.write('\\b');
      if (a['italic'] == true) on.write('\\i');
      if (a['underline'] == true) on.write('\\ul');
      if (a['strike'] == true) on.write('\\strike');
      if (a['color'] != null) on.write('\\cf${colourOf(a['color'])}');
      if (a['background'] != null) {
        on.write('\\highlight${colourOf(a['background'])}');
      }
      if (pt != null) on.write('\\fs${(pt * 2).round()}');
      body.write('{$on ${esc(r.text)}}');
    }
    body.write('\\par\n');
  }

  final head = StringBuffer('{\\rtf1\\ansi\\ansicpg1256\\deff0\\deflang1025');
  head.write('{\\fonttbl');
  for (var i = 0; i < fonts.length; i++) {
    head.write('{\\f$i\\fnil\\fcharset178 ${fonts[i]};}');
  }
  head.write('}{\\colortbl;');
  for (final c in colours) {
    final r = int.parse(c.substring(0, 2), radix: 16);
    final g = int.parse(c.substring(2, 4), radix: 16);
    final b = int.parse(c.substring(4, 6), radix: 16);
    head.write('\\red$r\\green$g\\blue$b;');
  }
  head.write('}{\\info{\\title ${esc(title)}}}\\viewkind4\\uc1\n');
  return Uint8List.fromList(latin1.encode('$head$body}'));
}
