import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Finds the word map that nots-cook (tools/cook) embeds in a PDF, without
/// parsing the PDF: the map is an attachment whose stream dictionary carries
/// the key /NotsWords, so a byte search finds it, and the stream right after
/// that dictionary is the map (JSON, usually Flate-compressed).
///
/// Returns the map's JSON text, or null when the PDF has none.
String? findWordMapJson(Uint8List pdf) {
  final marker = _lastIndexOf(pdf, latin1.encode('/NotsWords'), pdf.length);
  if (marker < 0) return null;
  // The dictionary starts after "N 0 obj" and ends at the "stream" keyword.
  final objStart = _lastIndexOf(pdf, latin1.encode('obj'), marker);
  var s = _indexOf(pdf, latin1.encode('stream'), marker);
  if (objStart < 0 || s < 0) return null;
  final head = latin1.decode(pdf.sublist(objStart, s));
  s += 6;
  if (s + 1 < pdf.length && pdf[s] == 0x0D && pdf[s + 1] == 0x0A) {
    s += 2;
  } else if (s < pdf.length && (pdf[s] == 0x0A || pdf[s] == 0x0D)) {
    s += 1;
  }
  final len = RegExp(r'/Length\s+(\d+)(\s+\d+\s+R)?').firstMatch(head);
  Uint8List body;
  if (len != null && len.group(2) == null) {
    final n = int.parse(len.group(1)!);
    if (s + n > pdf.length) return null;
    body = Uint8List.sublistView(pdf, s, s + n);
  } else {
    // Length kept elsewhere: the stream runs to "endstream".
    var e = _indexOf(pdf, latin1.encode('endstream'), s);
    if (e < 0) return null;
    while (e > s && (pdf[e - 1] == 0x0A || pdf[e - 1] == 0x0D)) {
      e--;
    }
    body = Uint8List.sublistView(pdf, s, e);
  }
  try {
    final bytes = head.contains('/FlateDecode') ? zlib.decode(body) : body;
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

int _indexOf(Uint8List data, List<int> pat, int from) {
  final first = pat[0];
  final last = data.length - pat.length;
  outer:
  for (var i = from; i <= last; i++) {
    if (data[i] != first) continue;
    for (var j = 1; j < pat.length; j++) {
      if (data[i + j] != pat[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Last start of [pat] that ends before [before].
int _lastIndexOf(Uint8List data, List<int> pat, int before) {
  final first = pat[0];
  outer:
  for (var i = before - pat.length; i >= 0; i--) {
    if (data[i] != first) continue;
    for (var j = 1; j < pat.length; j++) {
      if (data[i + j] != pat[j]) continue outer;
    }
    return i;
  }
  return -1;
}
