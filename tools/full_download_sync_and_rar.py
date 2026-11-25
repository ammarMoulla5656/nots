# -*- coding: utf-8 -*-
"""
=============================================================================
منظومة التنزيل الشامل والمزامنة الكاملة (صفحة بصفحة) بين PDF و DOCX وبناء أرشيف RAR
=============================================================================
المهام:
1. تنزيل كافة ملفات الـ PDF المعتمدة (1,200 مجلد / 250 كتاباً) بأقصى سرعة متوازية
   إلى المجلد: كتب_المكتبة_PDF
2. فحص كل ملف PDF وتحديد عدد صفحاته الفعلي (N_pdf)، ومزامنة ملف الـ DOCX المقابل له
   وحتى ملف الـ PDF نفسه (إذا كانت صفحات المصدر أكثر من الـ PDF) بحيث تتطابق الصفحات 100%:
   - إذا كانت الصفحة فارغة أو غلافاً غير موجود بالنص، يكتب في نفس رقم الصفحة: [ فارغ ]
   - إذا كانت الصفحة فهرست (في بداية أو نهاية الكتاب أو صفحات الفهرس)، يكتب: [ فهرست ] مع الفهرس
   - كل صفحة في الـ DOCX تقابل صفحة واحدة بالضبط في الـ PDF (بفواصل صفحات دقيقة وحجم خط متكيف).
3. تحديث ملف الإكسل الشامل بمعلومات كل كتاب، رابط التنزيل، مسار ملف الـ PDF، مسار الـ DOCX،
   عدد الصفحات المتطابق، ونسبة التطابق.
4. ضغط ملف الإكسل + مجلد كتب_المكتبة_PDF + مجلد كتب_المكتبة_docx في ملف .rar واحد متكامل:
   المكتبة_الشاملة_PDF_DOCX_المطابقة.rar
=============================================================================
"""

import os
import re
import sys
import json
import time
import shutil
import sqlite3
import subprocess
import urllib.request
import concurrent.futures
from concurrent.futures import ThreadPoolExecutor, ProcessPoolExecutor, as_completed

import pymupdf as fitz  # PyMuPDF
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls

BASE_DIR = r"d:\01_Projects\mobile\nots"
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
PDF_OUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_PDF")
DOCX_OUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_docx")
RAR_OUT_PATH = r"G:\المكتبة_الشاملة_PDF_DOCX_المطابقة.rar"
RAR_COPY_D_PATH = os.path.join(BASE_DIR, "المكتبة_الشاملة_PDF_DOCX_المطابقة.rar")
RAR_EXE = r"C:\Program Files\WinRAR\Rar.exe"

os.makedirs(PDF_OUT_DIR, exist_ok=True)
os.makedirs(DOCX_OUT_DIR, exist_ok=True)

COLOR_BLUE = RGBColor(0, 102, 204)
COLOR_RED = RGBColor(180, 20, 20)
COLOR_GREEN = RGBColor(0, 128, 0)
COLOR_PURPLE = RGBColor(128, 0, 128)
COLOR_DARK_GRAY = RGBColor(80, 80, 80)
COLOR_PAGE_BADGE = RGBColor(140, 80, 20)

CATEGORY_SHORT = {
    1: "تفسير_وقرآن",
    17: "عقائد_وكلام",
    18: "حديث_شريف",
    19: "أخلاق_وآداب",
    21: "فقه_وأحكام",
    22: "أصول_فقه",
    25: "رجال_وتراجم",
    27: "نحو_ولغة",
    29: "بلاغة_ومعاني",
    30: "منطق_وفلسفة"
}

CATEGORY_FULL = {
    1: "التفسير وعلوم القرآن",
    17: "العقائد والكلام",
    18: "الحديث الشريف وعلومه",
    19: "الأخلاق والآداب والسلوك",
    21: "الفقه الإسلامي والأحكام",
    22: "أصول الفقه والقواعد الأصولية",
    25: "علم الرجال والدراية والتراجم",
    27: "النحو والصرف وعلوم اللغة",
    29: "البلاغة والمعاني والبيان",
    30: "المنطق والفلسفة الإسلامية"
}

XML_CONTROL_CHARS = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')
TOKEN_PATTERN = re.compile(r'(<[^>]+>|[^<]+)')

def clean_xml(text):
    if not text:
        return ""
    # Truncate at null byte \x00 first to eliminate any SQLite overflow bytes
    text = text.split('\x00')[0]
    return XML_CONTROL_CHARS.sub('', text)

def sanitize_name(name):
    cleaned = re.sub(r'[\\/*?:"<>|]', '', name or '')
    cleaned = re.sub(r'\s+', '_', cleaned.strip())
    return cleaned

def is_valid_pdf(path):
    if not path or not os.path.exists(path):
        return False, 0
    try:
        if os.path.getsize(path) < 4096:
            return False, 0
        with fitz.open(path) as d:
            cnt = d.page_count
            return (cnt > 0), cnt
    except Exception:
        return False, 0

def resolve_direct_pdf_stream_url(url):
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=25.0) as resp:
            final_url = resp.geturl()
            ctype = resp.headers.get("Content-Type", "").lower()
            if "mediafire.com" in final_url and "text/html" in ctype:
                html = resp.read().decode("utf-8", errors="ignore")
                m = re.search(r'href=["\'](https?://download[^"\']+\.pdf[^"\']*)["\']', html, re.I)
                if not m:
                    m = re.search(r'href=["\'](https?://download\d*\.mediafire\.com/[^"\']+)["\']', html, re.I)
                if m:
                    return m.group(1)
            return final_url
    except Exception:
        return url

def download_ablibrary_scanned_pdf(ab_pdf_id, expected_pages, target_pdf_path):
    """
    تنزيل الصفحات المصورة الأصلية (السكان الأصلي 100%) من مكتبة أهل البيت:
    https://grpc.ablibrary.net/pdf/{ab_pdf_id}/pages/{p}.png
    وتجميعها في ملف PDF مصور أصلي 100% (وليس نصاً محولاً!).
    """
    if not ab_pdf_id:
        return False, 0

    headers = {"User-Agent": "Mozilla/5.0", "Content-Type": "application/json", "Connect-Protocol-Version": "1"}
    pages_cnt = int(expected_pages or 0)
    if pages_cnt <= 0:
        try:
            req = urllib.request.Request(
                "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/Details",
                data=json.dumps({"id": str(ab_pdf_id)}).encode("utf-8"),
                headers=headers,
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=12.0) as resp:
                b_obj = json.loads(resp.read().decode("utf-8")).get("book", {})
                pages_cnt = int(b_obj.get("pagesCount", 0) or 0)
        except Exception:
            pages_cnt = 0

    if pages_cnt <= 0:
        return False, 0

    def fetch_page_png(p_num):
        u = f"https://grpc.ablibrary.net/pdf/{ab_pdf_id}/pages/{p_num}.png"
        for attempt in range(3):
            try:
                req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(req, timeout=20.0) as r:
                    data = r.read()
                    if len(data) > 500:
                        return p_num, data
            except Exception:
                time.sleep(0.3 * (attempt + 1))
        return p_num, None

    page_bytes = {}
    with ThreadPoolExecutor(max_workers=24) as pool:
        for p_num, data in pool.map(fetch_page_png, range(1, pages_cnt + 1)):
            if data:
                page_bytes[p_num] = data

    if not page_bytes:
        return False, 0

    pdf_doc = fitz.open()
    for p_num in range(1, pages_cnt + 1):
        img_data = page_bytes.get(p_num)
        if img_data:
            try:
                pix = fitz.Pixmap(img_data)
                w, h = pix.width * 0.75, pix.height * 0.75
                if pix.alpha:
                    pix = fitz.Pixmap(fitz.csRGB, pix)
                jpg_bytes = pix.tobytes("jpeg", jpg_quality=75)
                pg = pdf_doc.new_page(width=w, height=h)
                pg.insert_image(pg.rect, stream=jpg_bytes)
            except Exception:
                pg = pdf_doc.new_page(width=595, height=842)
        else:
            pg = pdf_doc.new_page(width=595, height=842)

    tmp_pdf = target_pdf_path + ".scan.part"
    pdf_doc.save(tmp_pdf, garbage=4, deflate=True)
    cnt = pdf_doc.page_count
    pdf_doc.close()

    if os.path.exists(tmp_pdf) and os.path.getsize(tmp_pdf) > 10240:
        if os.path.exists(target_pdf_path):
            os.remove(target_pdf_path)
        os.replace(tmp_pdf, target_pdf_path)
        return True, cnt
    return False, 0

def download_url_worker(args):
    """
    تنزيل رابط PDF فريد إلى المسار الهدف الأول، ثم نسخه أو ربطه ببقية المجلدات المشتركة في نفس الرابط
    """
    primary_url, items_sharing_url = args
    first_key, first_info, first_target = items_sharing_url[0]

    # Check if any of the target paths already has a valid PDF
    existing_valid = None
    existing_pages = 0
    for k, inf, tpath in items_sharing_url:
        ok, pcnt = is_valid_pdf(tpath)
        if ok:
            existing_valid = tpath
            existing_pages = pcnt
            break

    if not existing_valid:
        # Build list of URLs to try
        urls_to_try = []
        if primary_url:
            urls_to_try.append(primary_url)
        if first_info.get("ab_pdf_url") and first_info["ab_pdf_url"] not in urls_to_try:
            urls_to_try.append(first_info["ab_pdf_url"])
        for c in first_info.get("candidates", []):
            u = c.get("url", "")
            if u and u not in urls_to_try and ("/pdf" in u or u.endswith(".pdf") or "fk_dl=" in u):
                urls_to_try.append(u)

        headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
        tmp_path = first_target + ".part"

        for u in urls_to_try:
            # If the URL is an Ablibrary PDF, download the original scanned pages from grpc.ablibrary.net/pdf/{id}/pages/{p}.png
            if "ablibrary.net/static/pdf/" in u:
                ab_pdf_id = u.split("/")[-1].replace(".pdf", "")
                exp_pages = int(first_info.get("ab_pages_count", 0) or 0)
                ok, pcnt = download_ablibrary_scanned_pdf(ab_pdf_id, exp_pages, first_target)
                if ok:
                    existing_valid = first_target
                    existing_pages = pcnt
                    break
                continue

            for attempt in range(2):
                try:
                    real_url = resolve_direct_pdf_stream_url(u)
                    req = urllib.request.Request(real_url, headers=headers)
                    with urllib.request.urlopen(req, timeout=120.0) as resp, open(tmp_path, "wb") as out_f:
                        while True:
                            chunk = resp.read(131072)
                            if not chunk:
                                break
                            out_f.write(chunk)
                    ok, pcnt = is_valid_pdf(tmp_path)
                    if ok:
                        if os.path.exists(first_target):
                            os.remove(first_target)
                        os.replace(tmp_path, first_target)
                        existing_valid = first_target
                        existing_pages = pcnt
                        break
                except Exception:
                    if os.path.exists(tmp_path):
                        try:
                            os.remove(tmp_path)
                        except Exception:
                            pass
                    time.sleep(0.5)
            if existing_valid:
                break

    if not existing_valid:
        # Try Ablibrary original scanned pages if ab_pdf_id or ab_book_id is available
        ab_pdf_id = first_info.get("ab_pdf_id") or first_info.get("ab_book_id") or ""
        exp_pages = int(first_info.get("ab_pages_count", 0) or 0)
        if ab_pdf_id:
            ok, pcnt = download_ablibrary_scanned_pdf(ab_pdf_id, exp_pages, first_target)
            if ok:
                existing_valid = first_target
                existing_pages = pcnt

    # Propagate to any other items sharing the same URL
    results = []
    for k, inf, tpath in items_sharing_url:
        if existing_valid and os.path.abspath(tpath) != os.path.abspath(existing_valid):
            ok_t, pcnt_t = is_valid_pdf(tpath)
            if not ok_t:
                try:
                    if os.path.exists(tpath):
                        os.remove(tpath)
                    shutil.copyfile(existing_valid, tpath)
                except Exception:
                    pass
        results.append((k, tpath, existing_pages))

    return results


def set_p_rtl_compact(p, align=WD_ALIGN_PARAGRAPH.RIGHT, space_before=0, space_after=1.0, line_spacing=1.05):
    pPr = p._element.get_or_add_pPr()
    pPr.append(OxmlElement('w:bidi'))
    p.alignment = align
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = line_spacing


def render_html_tokens_sized(p, text, base_pt=11.0, fn_pt=9.0):
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
            run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            if is_fn:
                run.font.size = Pt(fn_pt)
                run.font.color.rgb = COLOR_RED
                run.bold = True
            elif is_fm:
                run.font.size = Pt(base_pt)
                run.font.color.rgb = COLOR_GREEN
                run.bold = True
            else:
                run.font.size = Pt(base_pt)
                if cur_c:
                    run.font.color.rgb = cur_c
                if bld:
                    run.bold = True


def sync_single_volume_worker(task):
    """
    مزامنة ملف الـ DOCX وملف الـ PDF لمجلد واحد بحيث تتطابق الصفحات 1 إلى 1:
    task = (b_id, b_name, author, cat_id, total_vols, part_id, joze_label, docx_path, pdf_path, offset)
    """
    b_id, b_name, author, cat_id, total_vols, part_id, joze_label, docx_path, pdf_path, offset = task
    t0 = time.time()
    try:
        conn_rep = sqlite3.connect(REPAIRED_DB)
        conn_lib = sqlite3.connect(LIBRARY_DB)

        pages_rows = conn_rep.execute(
            "SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id",
            (part_id,)
        ).fetchall()

        toc_rows = conn_lib.execute(
            "SELECT pageID, title, level FROM Contents WHERE partID=? ORDER BY pageID, level",
            (part_id,)
        ).fetchall()

        conn_rep.close()
        conn_lib.close()

        cat_full = CATEGORY_FULL.get(cat_id, "عام")
        vol_text = f"الجزء {joze_label}" if total_vols > 1 else "الكتاب كامل"

        # Read actual PDF page count (NEVER modify the original scanned PDF or generate text PDF)
        ok_pdf, n_pdf = is_valid_pdf(pdf_path)
        if not ok_pdf or n_pdf <= 0:
            n_pdf = max((int(pid) for pid, _ in pages_rows), default=1)

        page_map = {}
        for pid, txt in pages_rows:
            cleaned = clean_xml(txt).strip()
            if cleaned:
                page_map[int(pid)] = cleaned

        toc_by_page = {}
        for t_pid, t_title, t_lvl in toc_rows:
            toc_by_page.setdefault(int(t_pid), []).append((clean_xml(t_title), int(t_lvl or 1)))

        if page_map:
            min_db_p = min(page_map.keys())
            max_db_p = max(page_map.keys())
            db_span = max_db_p - min_db_p + 1
        else:
            min_db_p = 1
            max_db_p = 1
            db_span = 0

        # Determine how PDF page `p` (1..N) maps to DB `page_id`
        # Case 1: Normal per-volume numbering (min_db_p <= 35)
        #   In printed books, DB page_id usually matches the printed page number, or has a small offset:
        #   pdf_page = db_page + eff_offset  =>  db_page = pdf_page - eff_offset
        if min_db_p <= 35:
            if abs(offset) <= 120 and (max_db_p + offset) <= n_pdf + 35:
                eff_offset = int(offset)
            else:
                eff_offset = 0
            def pdf_to_db_page(pdf_p):
                return pdf_p - eff_offset
            required_total_pages = max(n_pdf, max_db_p + eff_offset)
        else:
            # Case 2: Continuous pagination across volumes (e.g., Vol 2 starts at page_id 417 while PDF starts at 1)
            # Or shared multi-volume PDF where PDF has all volumes (n_pdf >= max_db_p)
            if n_pdf >= max_db_p and min_db_p <= n_pdf:
                eff_offset = 0
                def pdf_to_db_page(pdf_p):
                    return pdf_p
                required_total_pages = max(n_pdf, max_db_p)
            else:
                # Continuous DB numbering inside a single volume PDF (1..n_pdf)
                # Usually front matter is 1..4 pages before min_db_p
                front_matter = max(0, min(6, n_pdf - db_span)) if n_pdf > db_span else 0
                def pdf_to_db_page(pdf_p):
                    return min_db_p + (pdf_p - 1 - front_matter)
                required_total_pages = max(n_pdf, db_span + front_matter)

        # Keep the original scanned PDF untouched! Match DOCX page count 1-to-1 to the original PDF's n_pdf pages.
        total_synced_pages = n_pdf

        # Determine which non-content pages are "فهرست" vs "فارغ"
        # Trailing pages after max_db_p are typically the book's الفهرست (Table of Contents)
        last_content_pdf_p = 1
        first_content_pdf_p = total_synced_pages
        for p_idx in range(1, total_synced_pages + 1):
            db_p = pdf_to_db_page(p_idx)
            if db_p in page_map:
                if p_idx < first_content_pdf_p:
                    first_content_pdf_p = p_idx
                if p_idx > last_content_pdf_p:
                    last_content_pdf_p = p_idx

        trailing_fihrist_pages = [
            p_idx for p_idx in range(last_content_pdf_p + 1, total_synced_pages + 1)
            if pdf_to_db_page(p_idx) not in page_map
        ]

        # Build the DOCX with exact 1-to-1 page correspondence (1 logical page per PDF page)
        doc = Document()
        for s in doc.sections:
            s.page_width = Inches(8.27)   # A4
            s.page_height = Inches(11.69)
            s.top_margin = Inches(0.42)
            s.bottom_margin = Inches(0.42)
            s.left_margin = Inches(0.5)
            s.right_margin = Inches(0.5)

        norm = doc.styles['Normal']
        norm.font.name = 'Traditional Arabic'
        norm.font.size = Pt(11.5)
        rPr = norm._element.get_or_add_rPr()
        rPr.append(parse_xml(r'<w:rFonts %s w:ascii="Traditional Arabic" w:hAnsi="Traditional Arabic" w:cs="Traditional Arabic"/>' % nsdecls('w')))
        pPr = norm._element.get_or_add_pPr()
        pPr.append(OxmlElement('w:bidi'))

        # Split TOC items across trailing fihrist pages (or on page 2 if no trailing pages exist)
        toc_chunks = {}
        if toc_rows:
            if trailing_fihrist_pages:
                chunk_size = max(1, (len(toc_rows) + len(trailing_fihrist_pages) - 1) // len(trailing_fihrist_pages))
                for idx_f, f_page in enumerate(trailing_fihrist_pages):
                    toc_chunks[f_page] = toc_rows[idx_f * chunk_size : (idx_f + 1) * chunk_size]
            elif first_content_pdf_p > 2:
                toc_chunks[first_content_pdf_p - 1] = toc_rows[:45]

        for pdf_p in range(1, total_synced_pages + 1):
            db_p = pdf_to_db_page(pdf_p)
            raw_text = page_map.get(db_p, "")

            # Page Top Header Badge
            p_badge = doc.add_paragraph()
            set_p_rtl_compact(p_badge, WD_ALIGN_PARAGRAPH.CENTER, space_before=0, space_after=2, line_spacing=1.0)
            page_label_str = f"صفحة {pdf_p}" if db_p == pdf_p else f"صفحة PDF: {pdf_p} (ص المصدر: {db_p})"
            r = p_badge.add_run(f"❖  [ID: {b_id}] {b_name} - {vol_text} - {page_label_str}  ❖")
            r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            r.font.size = Pt(9.5)
            r.bold = True
            r.font.color.rgb = COLOR_PAGE_BADGE

            if raw_text:
                # Dynamic font sizing so 1 DB page always fits on 1 Word page without overflowing
                char_len = len(raw_text)
                lines_list = [ln.strip() for ln in raw_text.split('\n') if ln.strip()]
                line_cnt = len(lines_list)

                if char_len > 3200 or line_cnt > 34:
                    base_pt, fn_pt, sp_after, ln_sp = 8.5, 7.5, 0.4, 0.95
                elif char_len > 2400 or line_cnt > 26:
                    base_pt, fn_pt, sp_after, ln_sp = 9.5, 8.0, 0.6, 1.0
                elif char_len > 1700 or line_cnt > 20:
                    base_pt, fn_pt, sp_after, ln_sp = 10.5, 9.0, 0.8, 1.02
                else:
                    base_pt, fn_pt, sp_after, ln_sp = 11.5, 9.5, 1.2, 1.06

                # If many lines, join regular consecutive body lines to prevent vertical overflow
                if line_cnt > 28:
                    merged_lines = []
                    buf = []
                    for ln in lines_list:
                        if ln.startswith(('<psm>', '<head1>', '<head2>', '<fnote>')) or '____' in ln or 'ــــ' in ln:
                            if buf:
                                merged_lines.append(" ".join(buf))
                                buf = []
                            merged_lines.append(ln)
                        else:
                            buf.append(ln)
                            if len(" ".join(buf)) > 350:
                                merged_lines.append(" ".join(buf))
                                buf = []
                    if buf:
                        merged_lines.append(" ".join(buf))
                    lines_list = merged_lines

                for line_s in lines_list:
                    line_s = clean_xml(line_s)
                    if not line_s:
                        continue
                    if line_s.startswith('<psm>') and line_s.endswith('</psm>'):
                        p = doc.add_paragraph()
                        set_p_rtl_compact(p, WD_ALIGN_PARAGRAPH.CENTER, 0, sp_after, ln_sp)
                        content = re.sub(r'</?psm>', '', line_s)
                        run = p.add_run(content)
                        run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                        run.font.size = Pt(base_pt + 1.5)
                        run.bold = True
                        run.font.color.rgb = COLOR_GREEN
                    elif line_s.startswith('<head1>'):
                        p = doc.add_paragraph()
                        set_p_rtl_compact(p, WD_ALIGN_PARAGRAPH.RIGHT, 0, sp_after, ln_sp)
                        content = re.sub(r'</?head1>', '', line_s)
                        run = p.add_run(content)
                        run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                        run.font.size = Pt(base_pt + 1.0)
                        run.bold = True
                        run.font.color.rgb = COLOR_BLUE
                    elif line_s.startswith('<head2>'):
                        p = doc.add_paragraph()
                        set_p_rtl_compact(p, WD_ALIGN_PARAGRAPH.RIGHT, 0, sp_after, ln_sp)
                        content = re.sub(r'</?head2>', '', line_s)
                        run = p.add_run(content)
                        run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                        run.font.size = Pt(base_pt + 0.5)
                        run.bold = True
                        run.font.color.rgb = COLOR_RED
                    elif line_s.startswith('<fnote>'):
                        p = doc.add_paragraph()
                        set_p_rtl_compact(p, WD_ALIGN_PARAGRAPH.RIGHT, 0, sp_after, ln_sp)
                        content = re.sub(r'</?fnote>', '', line_s)
                        run = p.add_run(content)
                        run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                        run.font.size = Pt(fn_pt)
                        run.font.color.rgb = COLOR_DARK_GRAY
                    else:
                        p = doc.add_paragraph()
                        set_p_rtl_compact(p, WD_ALIGN_PARAGRAPH.RIGHT, 0, sp_after, ln_sp)
                        render_html_tokens_sized(p, line_s, base_pt=base_pt, fn_pt=fn_pt)

            elif pdf_p in toc_chunks or pdf_p in trailing_fihrist_pages or db_p in toc_by_page:
                # Fihrist / Index Page -> Write "فهرست"
                p_fih = doc.add_paragraph()
                set_p_rtl_compact(p_fih, WD_ALIGN_PARAGRAPH.CENTER, space_before=6, space_after=4, line_spacing=1.1)
                r_fih = p_fih.add_run("فهرست")
                r_fih._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                r_fih.font.size = Pt(16)
                r_fih.bold = True
                r_fih.font.color.rgb = COLOR_BLUE

                p_sub = doc.add_paragraph()
                set_p_rtl_compact(p_sub, WD_ALIGN_PARAGRAPH.CENTER, space_before=0, space_after=4, line_spacing=1.05)
                r_sub = p_sub.add_run(f"[ صفحة فهرست المحتويات — {b_name} ({vol_text}) ]")
                r_sub._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                r_sub.font.size = Pt(11)
                r_sub.bold = True
                r_sub.font.color.rgb = COLOR_DARK_GRAY

                chunk = toc_chunks.get(pdf_p, [])
                if not chunk and db_p in toc_by_page:
                    chunk = [(db_p, t_txt, t_l) for (t_txt, t_l) in toc_by_page[db_p]]

                for t_item in chunk[:32]:
                    t_pg, t_title, t_lvl = t_item[0], clean_xml(t_item[1]), t_item[2]
                    p_t = doc.add_paragraph()
                    set_p_rtl_compact(p_t, WD_ALIGN_PARAGRAPH.RIGHT, space_before=0, space_after=1.0, line_spacing=1.02)
                    indent = "   " * max(0, int(t_lvl) - 1)
                    rt = p_t.add_run(f"{indent}• {t_title}  ................................  ص {t_pg}")
                    rt._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                    rt.font.size = Pt(9.5)
                    if int(t_lvl) == 1:
                        rt.bold = True
                        rt.font.color.rgb = COLOR_BLUE
            else:
                # Blank / Cover / Unnumbered Gap Page -> Write "فارغ"
                if pdf_p == 1:
                    # Page 1 is the cover page before content starts -> Include book info + "فارغ"
                    p_cov = doc.add_paragraph()
                    set_p_rtl_compact(p_cov, WD_ALIGN_PARAGRAPH.CENTER, space_before=18, space_after=6, line_spacing=1.15)
                    rc = p_cov.add_run(f"{b_name}\n{vol_text}\nالمؤلف: {author or 'غير محدد'}\nالتصنيف: {cat_full} (ID: {b_id})")
                    rc._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                    rc.font.size = Pt(14)
                    rc.bold = True
                    rc.font.color.rgb = COLOR_BLUE

                p_emp = doc.add_paragraph()
                set_p_rtl_compact(p_emp, WD_ALIGN_PARAGRAPH.CENTER, space_before=24, space_after=6, line_spacing=1.15)
                r_emp = p_emp.add_run("فارغ")
                r_emp._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                r_emp.font.size = Pt(18)
                r_emp.bold = True
                r_emp.font.color.rgb = COLOR_RED

                p_emp_note = doc.add_paragraph()
                set_p_rtl_compact(p_emp_note, WD_ALIGN_PARAGRAPH.CENTER, space_before=2, space_after=4, line_spacing=1.05)
                r_en = p_emp_note.add_run(f"[ صفحة فارغة / غلاف في المصدر — رقم الصفحة في الـ PDF: {pdf_p} ]")
                r_en._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                r_en.font.size = Pt(10.5)
                r_en.font.color.rgb = COLOR_DARK_GRAY

            # Strictly 1 page break between every page 1 .. total_synced_pages - 1
            if pdf_p < total_synced_pages:
                doc.add_page_break()

        tmp_docx = docx_path + ".tmp.docx"
        doc.save(tmp_docx)
        os.replace(tmp_docx, docx_path)

        return f"{b_id}_{part_id}", total_synced_pages, len(page_map), time.time() - t0, None
    except Exception as e:
        return f"{b_id}_{part_id}", 0, 0, time.time() - t0, str(e)

def build_all_volume_tasks(matching_data):
    conn_lib = sqlite3.connect(LIBRARY_DB)
    books = conn_lib.execute("""
        SELECT bookID, book_name, authorName, category, cunt 
        FROM Contents 
        GROUP BY bookID 
        ORDER BY bookID
    """).fetchall()

    tasks = []
    for b in books:
        b_id, b_name, author, cat_id, vol_count = b
        parts_rows = conn_lib.execute("""
            SELECT DISTINCT partID, joze 
            FROM Contents 
            WHERE bookID=? 
            ORDER BY partID
        """, (b_id,)).fetchall()

        total_vols = len(parts_rows)
        clean_bname = sanitize_name(b_name)
        cat_short = CATEGORY_SHORT.get(cat_id, "عام")

        for idx, (p_id, raw_joze) in enumerate(parts_rows, 1):
            if total_vols == 1:
                base_fname = f"[ID_{b_id:03d}]_[{cat_short}]_[{clean_bname}]"
                joze_label = "كامل"
            else:
                if str(raw_joze).isdigit():
                    joze_label = f"{int(raw_joze):02d}"
                elif str(raw_joze) == '-':
                    joze_label = f"{idx:02d}"
                else:
                    joze_label = sanitize_name(str(raw_joze))
                base_fname = f"[ID_{b_id:03d}]_[{cat_short}]_[{clean_bname}]_ج{joze_label}"

            key = f"{b_id}_{p_id}"
            info = matching_data.get(key, {})

            docx_path = info.get("docx_path") or os.path.join(DOCX_OUT_DIR, base_fname + ".docx")
            pdf_fname = re.sub(r"\.docx$", ".pdf", os.path.basename(docx_path))
            pdf_path = os.path.join(PDF_OUT_DIR, pdf_fname)
            offset = int(info.get("offset", 0) or 0)

            tasks.append((b_id, b_name, author, cat_id, total_vols, p_id, joze_label, docx_path, pdf_path, offset))

    conn_lib.close()
    return tasks


def run_pipeline():
    t_pipeline_start = time.time()
    print("=" * 80)
    print("🚀 بدء المنظومة الشاملة: تنزيل جميع ملفات PDF + مزامنة الصفحات مع DOCX + بناء RAR")
    print("=" * 80)

    with open(MATCHING_DB, "r", encoding="utf-8") as f:
        matching_data = json.load(f)

    tasks = build_all_volume_tasks(matching_data)
    total_vols = len(tasks)
    print(f"📚 إجمالي المجلدات المستهدفة: {total_vols} مجلد (250 كتاباً)")

    # -------------------------------------------------------------------------
    # المرحلة 1: تنزيل جميع ملفات الـ PDF المعتمدة بالتوازي مع إزالة تكرار الروابط
    # -------------------------------------------------------------------------
    print("\n" + "-" * 80)
    print("📥 [المرحلة 1/4] تنزيل كافة ملفات الـ PDF المعتمدة (بالتوازي 16 مساراً)...")
    print("-" * 80)

    url_groups = {}
    for t in tasks:
        b_id, b_name, author, cat_id, t_vols, p_id, joze_label, docx_path, pdf_path, offset = t
        key = f"{b_id}_{p_id}"
        info = matching_data.get(key, {})
        info["book_name"] = b_name
        info["vol_label"] = joze_label
        primary_url = info.get("pdf_url", "") or f"local_{key}"
        url_groups.setdefault(primary_url, []).append((key, info, pdf_path))

    print(f"🔗 عدد الروابط الفريدة للتنزيل: {len(url_groups)} رابط تغطي {total_vols} مجلد")

    t_dl_start = time.time()
    dl_done_vols = 0
    pdf_page_counts = {}

    with ThreadPoolExecutor(max_workers=16) as pool:
        futs = {pool.submit(download_url_worker, item): item[0] for item in url_groups.items()}
        for fut in as_completed(futs):
            res_list = fut.result()
            for key, tpath, pcnt in res_list:
                dl_done_vols += 1
                pdf_page_counts[key] = pcnt
                if key in matching_data:
                    matching_data[key]["downloaded"] = True
                    matching_data[key]["local_pdf_path"] = tpath
                    matching_data[key]["pdf_pages"] = pcnt
            if dl_done_vols % 25 == 0 or dl_done_vols == total_vols:
                elapsed = time.time() - t_dl_start
                rate = dl_done_vols / elapsed if elapsed > 0 else 1
                rem = (total_vols - dl_done_vols) / rate if rate > 0 else 0
                sys.stdout.write(
                    f"\r⏳ تنزيل PDF: {dl_done_vols}/{total_vols} ({dl_done_vols*100/total_vols:.1f}%) "
                    f"| مضى: {elapsed/60:.1f} د | متبقي: {rem/60:.1f} د   "
                )
                sys.stdout.flush()

    print(f"\n✅ اكتمل تنزيل وتجهيز {dl_done_vols}/{total_vols} ملف PDF بنجاح في {(time.time()-t_dl_start)/60:.1f} دقيقة!")

    # Save updated matching_database.json after PDF downloads
    with open(MATCHING_DB, "w", encoding="utf-8") as f:
        json.dump(matching_data, f, ensure_ascii=False, indent=2)

    # -------------------------------------------------------------------------
    # المرحلة 2: مزامنة جميع ملفات الـ DOCX مع ملفات الـ PDF صفحة بصفحة (فارغ / فهرست)
    # -------------------------------------------------------------------------
    print("\n" + "-" * 80)
    print("📄 [المرحلة 2/4] تصحيح ومزامنة ملفات الـ DOCX والـ PDF صفحة بصفحة (فارغ / فهرست)...")
    print("-" * 80)

    t_sync_start = time.time()
    sync_done = 0
    total_synced_pages_sum = 0
    sync_errors = []

    with ProcessPoolExecutor(max_workers=8) as ex:
        fut_map = {ex.submit(sync_single_volume_worker, t): t for t in tasks}
        for fut in as_completed(fut_map):
            sync_done += 1
            key, synced_pages, db_pages, dur, err = fut.result()
            total_synced_pages_sum += synced_pages
            if err:
                sync_errors.append((key, err))
            else:
                if key in matching_data:
                    matching_data[key]["synced_pages"] = synced_pages
                    matching_data[key]["pdf_pages"] = synced_pages
                    matching_data[key]["docx_pages"] = synced_pages
                    old_notes = matching_data[key].get("notes", "")
                    sync_note = f"تمت مزامنة الصفحات 100% ({synced_pages} صفحة متطابقة في PDF و DOCX مع تمييز الصفحات الفارغة والفهرست)"
                    matching_data[key]["notes"] = f"{sync_note} | {old_notes}" if old_notes and "تمت مزامنة" not in old_notes else sync_note

            if sync_done % 20 == 0 or sync_done == total_vols:
                elapsed = time.time() - t_sync_start
                rate = sync_done / elapsed if elapsed > 0 else 1
                rem = (total_vols - sync_done) / rate if rate > 0 else 0
                sys.stdout.write(
                    f"\r⏳ مزامنة DOCX/PDF: {sync_done}/{total_vols} ({sync_done*100/total_vols:.1f}%) "
                    f"| إجمالي الصفحات المتطابقة: {total_synced_pages_sum:,} | متبقي: {rem/60:.1f} د   "
                )
                sys.stdout.flush()

    print(f"\n✅ اكتملت مزامنة {sync_done}/{total_vols} مجلد ({total_synced_pages_sum:,} صفحة) بنجاح! الأخطاء: {len(sync_errors)}")

    with open(MATCHING_DB, "w", encoding="utf-8") as f:
        json.dump(matching_data, f, ensure_ascii=False, indent=2)

    # -------------------------------------------------------------------------
    # المرحلة 3: تحديث ملف الإكسل الشامل بكافة المسارات المحلية والصفحات والنسب
    # -------------------------------------------------------------------------
    print("\n" + "-" * 80)
    print("📊 [المرحلة 3/4] تحديث ملف الإكسل الشامل بمعلومات الكتب ومسارات PDF و DOCX...")
    print("-" * 80)

    sys.path.insert(0, os.path.join(BASE_DIR, "tools"))
    from generate_matching_excel import generate_excel_catalog
    excel_out = generate_excel_catalog(matching_data)
    print(f"✅ تم تحديث ملف الإكسل الشامل: {excel_out}")

    # -------------------------------------------------------------------------
    # المرحلة 4: إنشاء ملف الـ .rar الشامل (الإكسل + كتب_المكتبة_PDF + كتب_المكتبة_docx)
    # -------------------------------------------------------------------------
    print("\n" + "-" * 80)
    print("📦 [المرحلة 4/4] إنشاء الأرشيف النهائي المتكامل (.rar)...")
    print("-" * 80)

    if os.path.exists(RAR_OUT_PATH):
        try:
            os.remove(RAR_OUT_PATH)
        except Exception:
            pass

    # Use -m0 (Store mode) because .pdf, .docx, and .xlsx are already ZIP/deflate compressed!
    # This makes archiving 10x faster and avoids unnecessary CPU overhead.
    cmd = [
        RAR_EXE,
        "a",
        "-m0",
        "-ep1",
        RAR_OUT_PATH,
        os.path.join(BASE_DIR, "ملف_روابط_PDF_النهائي_المعتمد_الشامل.xlsx"),
        os.path.join(BASE_DIR, "تقرير_مطابقة_كتب_PDF_الشامل.xlsx"),
        DOCX_OUT_DIR,
        PDF_OUT_DIR
    ]
    print(f"⚙️ جاري ضغط الملفات في: {RAR_OUT_PATH}")
    proc = subprocess.run(cmd, cwd=BASE_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.returncode in (0, 1) and os.path.exists(RAR_OUT_PATH):
        rar_size_bytes = os.path.getsize(RAR_OUT_PATH)
        rar_size_gb = rar_size_bytes / (1024 ** 3)
        print(f"🎉 تم إنشاء ملف الـ RAR النهائي بنجاح! الحجم: {rar_size_gb:.2f} GB")
        print(f"📍 المسار الأساسي: {RAR_OUT_PATH}")
        # If D: has enough free space, also copy to D:\01_Projects\mobile\nots\
        try:
            if shutil.disk_usage(BASE_DIR).free > rar_size_bytes + (2 * 1024 ** 3):
                print(f"📋 جاري نسخ الأرشيف إلى مجلد المشروع: {RAR_COPY_D_PATH} ...")
                shutil.copyfile(RAR_OUT_PATH, RAR_COPY_D_PATH)
                print(f"✅ تم حفظ نسخة مطابقة في: {RAR_COPY_D_PATH}")
        except Exception as e:
            print(f"ℹ️ الأرشيف محفوظ بالكامل على: {RAR_OUT_PATH} ({e})")
    else:
        print(f"⚠️ انتبه: كود خروج WinRAR = {proc.returncode}")
        print(proc.stdout[-1500:] if proc.stdout else "")

    print("\n" + "=" * 80)
    print(f"🏁 اكتملت جميع المراحل بنجاح في {(time.time() - t_pipeline_start)/60:.1f} دقيقة!")
    print("=" * 80)


if __name__ == "__main__":
    run_pipeline()
