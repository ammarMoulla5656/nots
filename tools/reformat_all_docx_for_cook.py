import os
import sys
import re
import time
import json
import sqlite3
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed

from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls
import pymupdf as fitz

MATCHING_DB_PATH = r"d:\01_Projects\mobile\nots\matching_database.json"
REPAIRED_DB = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"
LIBRARY_DB = r"d:\01_Projects\mobile\nots\library.db"
DOCX_DIR = r"d:\01_Projects\mobile\nots\كتب_المكتبة_docx"
PDF_DIR = r"d:\01_Projects\mobile\nots\كتب_المكتبة_PDF"

COLOR_BLUE = RGBColor(0, 102, 204)
COLOR_RED = RGBColor(180, 20, 20)
COLOR_GREEN = RGBColor(0, 128, 0)
COLOR_PURPLE = RGBColor(128, 0, 128)
COLOR_DARK_GRAY = RGBColor(80, 80, 80)
COLOR_MUTED = RGBColor(110, 110, 110)

XML_CONTROL_CHARS = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')
TOKEN_PATTERN = re.compile(r'(<[^>]+>|[^<]+)')
HEAD_TAG_RE = re.compile(r'</?(?:head\d|psm|fnote|fn|fm|blue|red|green|msaleh)[^>]*>', re.IGNORECASE)

def clean_xml(text):
    if not text:
        return ""
    return XML_CONTROL_CHARS.sub('', text)

def strip_tags(text):
    if not text:
        return ""
    return HEAD_TAG_RE.sub('', text).strip()

def set_p_rtl(p, align=WD_ALIGN_PARAGRAPH.RIGHT):
    pPr = p._element.get_or_add_pPr()
    pPr.append(OxmlElement('w:bidi'))
    p.alignment = align

def render_tokens(p, text, base_size=10.5):
    tokens = TOKEN_PATTERN.findall(clean_xml(text))
    cur_c = None
    bld = False
    is_fn = False
    is_fm = False

    for tok in tokens:
        if not tok:
            continue
        low = tok.lower()
        if low == '<blue>':
            cur_c = COLOR_BLUE
        elif low == '</blue>':
            cur_c = None
        elif low == '<red>':
            cur_c = COLOR_RED
        elif low == '</red>':
            cur_c = None
        elif low == '<green>':
            cur_c = COLOR_GREEN
        elif low == '</green>':
            cur_c = None
        elif low == '<msaleh>':
            cur_c = COLOR_PURPLE
            bld = True
        elif low == '</msaleh>':
            cur_c = None
            bld = False
        elif low == '<fn>':
            is_fn = True
        elif low == '</fn>':
            is_fn = False
        elif low == '<fm>':
            is_fm = True
        elif low == '</fm>':
            is_fm = False
        elif low.startswith('<') and low.endswith('>'):
            continue
        else:
            run = p.add_run(tok)
            if is_fn:
                run.font.size = Pt(base_size - 1.5)
                run.font.color.rgb = COLOR_RED
                run.bold = True
            elif is_fm:
                run.font.color.rgb = COLOR_GREEN
                run.bold = True
            else:
                if cur_c:
                    run.font.color.rgb = cur_c
                if bld:
                    run.bold = True

def process_single_volume(entry_info):
    key, v_info = entry_info
    t0 = time.time()
    try:
        parts = key.split('_')
        b_id = int(parts[0])
        part_id = int(parts[1])

        docx_path = v_info.get('docx_path')
        if not docx_path:
            docx_path = os.path.join(DOCX_DIR, f"[ID_{b_id:03d}]_{part_id}.docx")

        local_pdf_path = v_info.get('local_pdf_path', '')
        offset = int(v_info.get('offset', 0) or 0)

        # 1. Determine PDF page count
        n_pdf = 0
        if local_pdf_path and os.path.exists(local_pdf_path) and os.path.getsize(local_pdf_path) > 10000:
            try:
                doc_pdf = fitz.open(local_pdf_path)
                n_pdf = doc_pdf.page_count
                doc_pdf.close()
            except Exception:
                n_pdf = int(v_info.get('pdf_pages', 0) or 0)
        else:
            n_pdf = int(v_info.get('pdf_pages', 0) or 0)

        # 2. Query BookPages from alhikmeh_repaired.db
        conn_rep = sqlite3.connect(REPAIRED_DB, timeout=30.0)
        c_rep = conn_rep.cursor()
        c_rep.execute("SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id", (part_id,))
        rows = c_rep.fetchall()
        conn_rep.close()

        if not rows:
            return key, False, 0, "No pages in DB"

        db_pages = {}
        for p_id, txt in rows:
            clean_txt = (txt or "").split('\x00')[0].strip()
            db_pages[int(p_id)] = clean_txt

        min_db_p = min(db_pages.keys())
        max_db_p = max(db_pages.keys())
        db_span = max_db_p - min_db_p + 1

        if n_pdf <= 0:
            n_pdf = max(max_db_p + offset, len(db_pages))

        # 3. Query TOC from library.db
        toc_by_page = {}
        try:
            conn_lib = sqlite3.connect(LIBRARY_DB, timeout=30.0)
            c_lib = conn_lib.cursor()
            c_lib.execute("SELECT pageID, title, level FROM Contents WHERE partID=? ORDER BY pageID, level", (part_id,))
            for p_id, title, lvl in c_lib.fetchall():
                clean_t = strip_tags(title)
                if clean_t:
                    toc_by_page.setdefault(int(p_id), []).append((lvl, clean_t))
            conn_lib.close()
        except Exception:
            pass

        # 4. Create Document
        doc = Document()
        for s in doc.sections:
            s.page_width = Inches(8.27)
            s.page_height = Inches(11.69)
            s.top_margin = Inches(0.4)
            s.bottom_margin = Inches(0.4)
            s.left_margin = Inches(0.5)
            s.right_margin = Inches(0.5)

        norm = doc.styles['Normal']
        norm.font.name = 'Traditional Arabic'
        norm.font.size = Pt(11)
        rPr = norm._element.get_or_add_rPr()
        rPr.append(parse_xml(r'<w:rFonts %s w:ascii="Traditional Arabic" w:hAnsi="Traditional Arabic" w:cs="Traditional Arabic"/>' % nsdecls('w')))
        pPr = norm._element.get_or_add_pPr()
        pPr.append(OxmlElement('w:bidi'))

        # Setup Heading 1 & Heading 2 styles
        for h_name, h_sz, h_col in [('Heading 1', 13.5, COLOR_BLUE), ('Heading 2', 12.0, COLOR_RED)]:
            try:
                st = doc.styles[h_name]
                st.font.name = 'Traditional Arabic'
                st.font.size = Pt(h_sz)
                st.font.color.rgb = h_col
                st.font.bold = True
                h_rPr = st._element.get_or_add_rPr()
                h_rPr.append(parse_xml(r'<w:rFonts %s w:ascii="Traditional Arabic" w:hAnsi="Traditional Arabic" w:cs="Traditional Arabic"/>' % nsdecls('w')))
                h_pPr = st._element.get_or_add_pPr()
                h_pPr.append(OxmlElement('w:bidi'))
            except Exception:
                pass

        # 5. Build pages 1 .. N_pdf
        for pdf_p in range(1, n_pdf + 1):
            # Compute db_p
            if min_db_p <= 35:
                db_p = pdf_p - offset
            else:
                if n_pdf >= max_db_p and min_db_p <= n_pdf:
                    db_p = pdf_p
                else:
                    front_matter = max(0, min(6, n_pdf - db_span)) if n_pdf > db_span else 0
                    db_p = min_db_p + (pdf_p - 1 - front_matter)

            raw_text = db_pages.get(db_p, '') if db_p is not None else ''

            if not raw_text:
                # Blank / Gap / Cover page
                p_blank = doc.add_paragraph('بياض مطابق للأصل')
                set_p_rtl(p_blank, WD_ALIGN_PARAGRAPH.CENTER)
            else:
                # Text page: first paragraph is [صفحة {pdf_p}]
                p_marker = doc.add_paragraph(f'[صفحة {pdf_p}]')
                set_p_rtl(p_marker, WD_ALIGN_PARAGRAPH.CENTER)

                # TOC Headings if any on this page
                if db_p in toc_by_page:
                    for lvl, h_title in toc_by_page[db_p]:
                        h_style = 'Heading 1' if lvl == 1 else 'Heading 2'
                        p_h = doc.add_paragraph(h_title, style=h_style)
                        set_p_rtl(p_h, WD_ALIGN_PARAGRAPH.RIGHT)

                # Body text lines
                lines = raw_text.splitlines()
                # Determine dynamic base font size based on page length
                total_len = len(raw_text)
                base_font_sz = 9.5 if total_len > 2200 else (10.5 if total_len > 1400 else 11.5)

                for line in lines:
                    line_s = line.strip()
                    if not line_s:
                        continue

                    low = line_s.lower()
                    if low.startswith('<psm>') and low.endswith('</psm>'):
                        p_psm = doc.add_paragraph()
                        set_p_rtl(p_psm, WD_ALIGN_PARAGRAPH.CENTER)
                        r = p_psm.add_run(strip_tags(line_s))
                        r.font.size = Pt(base_font_sz + 1.5)
                        r.bold = True
                        r.font.color.rgb = COLOR_GREEN
                    elif low.startswith('<head1>'):
                        p_hd = doc.add_paragraph(strip_tags(line_s), style='Heading 1')
                        set_p_rtl(p_hd, WD_ALIGN_PARAGRAPH.RIGHT)
                    elif low.startswith('<head2>'):
                        p_hd = doc.add_paragraph(strip_tags(line_s), style='Heading 2')
                        set_p_rtl(p_hd, WD_ALIGN_PARAGRAPH.RIGHT)
                    elif low.startswith('<fnote>'):
                        p_fn = doc.add_paragraph()
                        set_p_rtl(p_fn, WD_ALIGN_PARAGRAPH.JUSTIFY)
                        render_tokens(p_fn, line_s, base_size=base_font_sz - 1.5)
                    else:
                        p_body = doc.add_paragraph()
                        set_p_rtl(p_body, WD_ALIGN_PARAGRAPH.JUSTIFY)
                        render_tokens(p_body, line_s, base_size=base_font_sz)

            # Add explicit page break between pages
            if pdf_p < n_pdf:
                doc.add_page_break()

        # Save atomically
        os.makedirs(os.path.dirname(docx_path), exist_ok=True)
        tmp_path = docx_path + ".tmp.docx"
        doc.save(tmp_path)
        if os.path.exists(docx_path):
            try:
                os.remove(docx_path)
            except Exception:
                pass
        os.replace(tmp_path, docx_path)

        dt = time.time() - t0
        return key, True, n_pdf, f"OK ({dt:.2f}s)"
    except Exception as e:
        return key, False, 0, str(e)

def main():
    print("=" * 70)
    print("REFORMATTING ALL DOCX FILES FOR COOK.PY ACCORDING TO SPECIFICATIONS")
    print("=" * 70)

    with open(MATCHING_DB_PATH, "r", encoding="utf-8") as f:
        match_db = json.load(f)

    items = list(match_db.items())
    total = len(items)
    print(f"Total volumes to process: {total}")

    success_cnt = 0
    fail_cnt = 0
    t_start = time.time()

    workers = max(1, os.cpu_count() - 2)
    print(f"Using {workers} parallel worker processes...")

    with ProcessPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(process_single_volume, item): item[0] for item in items}
        done = 0
        for future in as_completed(futures):
            key = futures[future]
            try:
                k, ok, pages, msg = future.result()
                done += 1
                if ok:
                    success_cnt += 1
                else:
                    fail_cnt += 1
                if done % 25 == 0 or done == total:
                    elapsed = time.time() - t_start
                    rate = done / elapsed if elapsed > 0 else 0
                    remaining = (total - done) / rate if rate > 0 else 0
                    print(f"[{done}/{total}] {key} -> {msg} | Pages: {pages} | {rate:.1f} vols/sec | ETA: {remaining/60:.1f}m")
            except Exception as exc:
                done += 1
                fail_cnt += 1
                print(f"[{done}/{total}] {key} generated an exception: {exc}")

    t_total = time.time() - t_start
    print("=" * 70)
    print(f"COMPLETED in {t_total:.1f}s ({t_total/60:.2f} min)")
    print(f"Success: {success_cnt} | Failed: {fail_cnt}")
    print("=" * 70)

if __name__ == "__main__":
    main()
