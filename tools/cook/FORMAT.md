# nots-words: the word map inside a linked PDF

A PDF made by `cook.py` is the original PDF, drawn exactly as before, plus:

1. a corrected text layer (`/ToUnicode` of the fonts), so any PDF viewer
   copies and searches real text;
2. bookmarks (the table of contents) from the source text's headings;
3. one attachment, `nots-words.json`: the **word map** described here.

The word map is what apps use to link a place on the page with a word of
the book's text, and a word of the text with its place on the page.

## Finding it

It is a standard PDF attachment (EmbeddedFiles name tree), readable with
any PDF library. The attachment's stream dictionary also carries the key
`/NotsWords true`, so a reader can find it without a PDF parser: search the
file bytes for the last `/NotsWords`, take the stream that follows that
dictionary (`/Length` bytes after the `stream` keyword and its line end),
and inflate it when the dictionary says `/FlateDecode`. The app does this in
`app/lib/book/word_map.dart`.

## Contents (JSON, UTF-8)

```json
{
  "format": "nots-words",
  "version": 1,
  "generator": "nots-cook 1.0.0",
  "created": "2026-11-02T12:00:00+00:00",
  "title": "المسائل المنتخبة",
  "lang": "ar",
  "source": {
    "pdf": "arabic-mmontakhab-1441h.pdf",
    "pdfId": "1f0e…",          // book id of the original PDF (see below)
    "text": "المسائل المنتخبة … .docx",
    "method": "fonts+text"
  },
  "units": "pt/10 deltas, top-left origin, unrotated page",
  "pageCount": 544,
  "wordCount": 109161,
  "pages": [
    {"k": "text", "s": [595.44, 841.92], "t": "…", "b": [ … ]}
  ],
  "headings": [{"t": "التقليد", "l": 1, "p": 17, "w": 2310}]
}
```

### Pages

`pages[i]` is PDF page `i + 1`.

- `k`: `text` (words placed from the PDF's glyphs), `ocr` (placed by OCR),
  `image` (a picture: its text is known, its places are not), `blank`.
- `s`: page width and height in points.
- `t`: the page's text, **exactly** as in the source (Word) file: words
  separated by one space, paragraphs by one line break (`\n`). No other
  white space occurs. Editorial notes of the transcriber
  ("[صفحة بصورة مطابق للأصل]", "بياض مطابق للأصل") are not part of it.
- `b`: the place of each word of `t`, in order. Per word either four
  integers or one `null`:
  - four integers: `x0, y0, x1, y1` of the word's box in tenths of a point,
    origin at the top-left corner of the page, each written as the
    difference from the same value of the previous placed word of the page
    (the first placed word counts from 0). Decode with a running sum.
  - `null`: the word's place is unknown (picture pages, words the PDF does
    not draw).

### Words and their ids

A word is a run of characters between separators in `t`. Its **id** is its
index in the whole book: page 1's words are 0, 1, 2, …, page 2 continues
where page 1 stopped, and so on (`wordCount` words in all).

The id is the link between apps. A mark or a comment made in Nots stores
the ids of its first and last word (`NoteItem.wordFrom`/`wordTo`, ink file
format 4); another app reading the same map (Al-Hikma, which shows the
text) finds the same words by the same ids, whatever its layout, font or
screen. `quote` keeps the words' text as well, to check against.

### Headings

`t` title, `l` level (1 = main), `p` PDF page, `w` id of the heading's
first word.

### pdfId

The book id Nots gives the original PDF: FNV-1a 64 over the text
`"<size>|"`, the first megabyte and the last megabyte of the file, as 16
hex digits (`fingerprintFile` in `app/lib/library/library_store.dart`).
Writing done on the original lines up with the linked edition exactly
(same pages, same places), so the app offers to bring it over.
