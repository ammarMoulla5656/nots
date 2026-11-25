# -*- coding: utf-8 -*-
"""
Fast Book Matching & Isolation Tool (Masaha <-> Source)
- Compares sampled body pages (ignoring extra headers/intros/footnotes and minor spelling variants).
- Accepts matches >= 80% immediately without comparing entire books.
- Isolates matching Masaha EPUB + Masaha PDF pairs into a numbered folder.
- Generates a comprehensive Excel report with full metadata and all file paths.
"""

import os
import re
import sys
import json
import time
import shutil
import sqlite3
import zipfile
from pathlib import Path
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

BASE_DIR = r"d:\01_Projects\mobile\nots"
MASAHA_DIR = os.path.join(BASE_DIR, "كتب مساحة حرة")
MASAHA_BOOKS_DIR = os.path.join(MASAHA_DIR, "الكتب")
MASAHA_DB = os.path.join(MASAHA_DIR, "masaha_state.db")

REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
MATCHING_DB_JSON = os.path.join(BASE_DIR, "matching_database.json")

OUT_DIR = os.path.join(BASE_DIR, "كتب_مساحة_حرة_المتشابهة")
OUT_EXCEL = os.path.join(BASE_DIR, "تقرير_الكتب_المتشابهة_مساحة_حرة_والمصدر.xlsx")

MATCH_THRESHOLD = 80.0  # 80% threshold (80-100%)

# Regexes for fast normalization
TAG_RE = re.compile(r'<[^>]+>')
FN_RE = re.compile(r'<(?:fn|fnote)>.*?</(?:fn|fnote)>', re.DOTALL | re.IGNORECASE)
DIACRITICS_RE = re.compile(r'[\u064B-\u065F\u0670\u0640]')
NON_ARABIC_RE = re.compile(r'[^\u0621-\u064A\s]')
MULTI_SPACE_RE = re.compile(r'\s+')
DROP_NOISE_RE = re.compile(r'\[صفحة\s*\d+\]|بياض\s+مطابق\s+للأصل')

NORM_TRANS = str.maketrans({
    'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
    'ى': 'ي',
    'ة': 'ه',
    'ؤ': 'و',
    'ئ': 'ي',
})

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
    30: "المنطق والفلسفة الإسلامية",
}


def normalize_ar(text: str) -> str:
    if not text:
        return ""
    text = DROP_NOISE_RE.sub(' ', text)
    text = FN_RE.sub(' ', text)
    text = TAG_RE.sub(' ', text)
    text = DIACRITICS_RE.sub('', text)
    text = text.translate(NORM_TRANS)
    text = NON_ARABIC_RE.sub(' ', text)
    return MULTI_SPACE_RE.sub(' ', text).strip()


def make_shingles(words: list[str], k: int = 5, step: int = 1) -> set[str]:
    n = len(words)
    if n < k:
        return set()
    return {' '.join(words[i:i + k]) for i in range(0, n - k + 1, step)}


def sanitize_filename(name: str, max_len: int = 90) -> str:
    name = re.sub(r'[\\/:*?"<>|\r\n\t]+', '_', name).strip(' ._')
    if len(name) > max_len:
        name = name[:max_len].strip(' ._')
    return name or "book"


def load_masaha_catalog():
    """Load Masaha catalog metadata and local EPUB/PDF file map."""
    meta = {}
    conn = sqlite3.connect(MASAHA_DB)
    for row in conn.execute("SELECT id, title, raw FROM catalog"):
        mid, title, raw_json = row
        info = {"id": mid, "title": title or "", "joze": "", "pages": 0, "author": "", "category": "", "url": f"https://www.masaha.org/book/{mid}"}
        if raw_json:
            try:
                d = json.loads(raw_json)
                info["title"] = d.get("title") or info["title"]
                info["joze"] = str(d.get("joze") or "").strip()
                info["pages"] = int(d.get("pages_count") or 0)
                authors = d.get("authors") or []
                if authors and isinstance(authors, list):
                    info["author"] = authors[0].get("name", "")
                cat = d.get("category") or {}
                if isinstance(cat, dict):
                    info["category"] = cat.get("title", "")
                if d.get("bookUrl"):
                    info["url"] = d["bookUrl"]
            except Exception:
                pass
        meta[int(mid)] = info
    conn.close()

    epubs = {}
    pdfs = {}
    for fname in os.listdir(MASAHA_BOOKS_DIR):
        m = re.match(r'^(\d+)\s*-', fname)
        if not m:
            continue
        mid = int(m.group(1))
        fpath = os.path.join(MASAHA_BOOKS_DIR, fname)
        low = fname.lower()
        if low.endswith(".epub"):
            epubs[mid] = fpath
        elif low.endswith(".pdf"):
            pdfs[mid] = fpath

    return meta, epubs, pdfs


def extract_epub_sample_shingles(args):
    """Extract 4-word shingles from ~40 evenly-spaced HTML pages of an EPUB."""
    mid, epub_path = args
    shingles = set()
    try:
        with zipfile.ZipFile(epub_path, 'r') as z:
            htmls = sorted(n for n in z.namelist() if n.lower().endswith(('.html', '.xhtml', '.htm')))
            if not htmls:
                return mid, shingles, 0
            lo = max(0, int(len(htmls) * 0.08))
            hi = min(len(htmls), int(len(htmls) * 0.92))
            body_htmls = htmls[lo:hi] if hi > lo else htmls
            step = max(1, len(body_htmls) // 40)
            sampled = body_htmls[::step]
            for name in sampled:
                raw = z.read(name).decode('utf-8', 'ignore')
                norm = normalize_ar(raw)
                words = norm.split()
                if len(words) >= 8:
                    shingles.update(make_shingles(words, k=4, step=2))
            return mid, shingles, len(htmls)
    except Exception:
        return mid, shingles, 0


def read_epub_content_sets(epub_path: str):
    """Read content words (>=4 chars) and bigrams from an EPUB for fast containment verification."""
    ep_words = set()
    ep_bigrams = set()
    html_count = 0
    try:
        with zipfile.ZipFile(epub_path, 'r') as z:
            htmls = [n for n in z.namelist() if n.lower().endswith(('.html', '.xhtml', '.htm'))]
            html_count = len(htmls)
            for name in htmls:
                raw = z.read(name).decode('utf-8', 'ignore')
                ws = normalize_ar(raw).split()
                for w in ws:
                    if len(w) >= 4:
                        ep_words.add(w)
                for i in range(len(ws) - 1):
                    ep_bigrams.add(ws[i] + ' ' + ws[i + 1])
    except Exception:
        pass
    return ep_words, ep_bigrams, html_count


def get_source_books():
    """Load all 1,200 source parts with metadata and sampled body pages."""
    with open(MATCHING_DB_JSON, "r", encoding="utf-8") as f:
        match_db = json.load(f)

    conn = sqlite3.connect(REPAIRED_DB)
    books_meta = {}
    for row in conn.execute("SELECT id, book_name, authorName, category, parts_count FROM Books"):
        books_meta[int(row[0])] = {
            "book_name": row[1] or "",
            "author": row[2] or "",
            "category": CATEGORY_FULL.get(row[3], str(row[3] or "")),
            "parts_count": int(row[4] or 1),
        }

    parts_pages = defaultdict(list)
    for pid, page_id, text in conn.execute("SELECT part_id, page_id, text FROM BookPages ORDER BY part_id, page_id"):
        if text and len(text.strip()) > 60:
            parts_pages[int(pid)].append((int(page_id), text.split('\x00')[0]))
    conn.close()

    sources = []
    for key, v in match_db.items():
        b_id, part_id = map(int, key.split('_'))
        binfo = books_meta.get(b_id, {})
        pages = parts_pages.get(part_id, [])
        if not pages:
            continue

        # Sample 12 evenly spaced body pages from 15%..85%
        lo = max(0, int(len(pages) * 0.15))
        hi = min(len(pages), int(len(pages) * 0.85))
        body = pages[lo:hi] if hi - lo >= 10 else pages
        step = max(1, len(body) // 12)
        sampled_pages = body[::step][:12]

        sample_shingles_4 = set()
        sample_page_data = []  # list of (content_words_set, bigrams_set)
        for _, txt in sampled_pages:
            ws = normalize_ar(txt).split()
            if len(ws) >= 12:
                sample_shingles_4.update(make_shingles(ws, k=4, step=1))
                cw = {w for w in ws if len(w) >= 4}
                bg = {ws[i] + ' ' + ws[i + 1] for i in range(len(ws) - 1)}
                sample_page_data.append((cw, bg))

        hint_mid = None
        m_url = v.get("masaha_url") or v.get("pdf_url") or ""
        m_hint = re.search(r'/book/(\d+)', m_url)
        if m_hint:
            hint_mid = int(m_hint.group(1))

        sources.append({
            "key": key,
            "book_id": b_id,
            "part_id": part_id,
            "book_name": binfo.get("book_name") or v.get("book_name") or "",
            "author": binfo.get("author") or "",
            "category": binfo.get("category") or "",
            "vol_label": str(v.get("vol_label") or ""),
            "pages_count": len(pages),
            "docx_path": v.get("docx_path") or "",
            "source_pdf_path": v.get("local_pdf_path") or "",
            "hint_mid": hint_mid,
            "shingles_4": sample_shingles_4,
            "sample_page_data": sample_page_data,
        })

    return sources


def verify_source_against_epub(src, epub_path: str, epub_cache: dict) -> float:
    """
    Verify sampled Source body pages against candidate Masaha EPUB using
    content-word containment + ordered bigram containment + per-page spread.
    Ignores extra text (covers, headers, footnotes, colophons) on both sides.
    """
    sample_page_data = src["sample_page_data"]
    if not sample_page_data:
        return 0.0

    if epub_path not in epub_cache:
        epub_cache[epub_path] = read_epub_content_sets(epub_path)
    ep_words, ep_bigrams, _ = epub_cache[epub_path]
    if not ep_words:
        return 0.0

    tot_w = hit_w = tot_b = hit_b = 0
    pages_strong = 0

    for cw, bg in sample_page_data:
        if not cw or not bg:
            continue
        wh = len(cw & ep_words)
        bh = len(bg & ep_bigrams)
        tot_w += len(cw)
        hit_w += wh
        tot_b += len(bg)
        hit_b += bh
        # A true matching page typically has >= 70% content words and >= 55% bigrams
        if (wh / len(cw) >= 0.70) and (bh / len(bg) >= 0.50):
            pages_strong += 1

    if tot_w == 0 or tot_b == 0:
        return 0.0

    w_ratio = hit_w / tot_w
    b_ratio = hit_b / tot_b
    combined = (0.55 * w_ratio) + (0.45 * b_ratio)

    # Require at least half of sampled pages to align strongly to prevent false matches
    if pages_strong < max(3, len(sample_page_data) // 2):
        combined *= 0.65

    return round(combined * 100.0, 2)


def main():
    t_start = time.time()
    print("=" * 70)
    print("FAST BOOK MATCHING & ISOLATION: MASAHA <-> SOURCE (WORD + BIGRAM)")
    print("=" * 70)

    print("[1/5] Loading Masaha catalog and local EPUB/PDF files...")
    masaha_meta, masaha_epubs, masaha_pdfs = load_masaha_catalog()
    print(f"      Found {len(masaha_epubs)} Masaha EPUBs, {len(masaha_pdfs)} Masaha PDFs.")

    print("[2/5] Loading Source books and sampling body pages...")
    sources = get_source_books()
    print(f"      Loaded {len(sources)} Source volumes.")

    epub_cache = {}
    matched_results = []
    unmatched_sources = []

    print("[3/5] Fast pass: verifying direct Masaha ID hints...")
    t1 = time.time()
    for idx, src in enumerate(sources, 1):
        hmid = src["hint_mid"]
        if hmid and hmid in masaha_epubs:
            score = verify_source_against_epub(src, masaha_epubs[hmid], epub_cache)
            if score >= MATCH_THRESHOLD:
                matched_results.append((src, hmid, score))
                continue
        unmatched_sources.append(src)
        if idx % 300 == 0:
            print(f"      Checked {idx}/{len(sources)} hints -> {len(matched_results)} matched...")
    print(f"      Direct hints matched: {len(matched_results)} | Remaining for shingle search: {len(unmatched_sources)} ({time.time()-t1:.1f}s)")

    if unmatched_sources:
        print("[4/5] Building fast inverted 4-word shingle index across Masaha EPUBs...")
        t2 = time.time()
        inv_index = defaultdict(list)
        epub_items = list(masaha_epubs.items())
        with ThreadPoolExecutor(max_workers=12) as ex:
            for idx, (mid, sh_set, _) in enumerate(ex.map(extract_epub_sample_shingles, epub_items), 1):
                for sh in sh_set:
                    inv_index[sh].append(mid)
                if idx % 400 == 0 or idx == len(epub_items):
                    print(f"      Indexed {idx}/{len(epub_items)} EPUBs...")
        print(f"      Inverted index built in {time.time()-t2:.1f}s ({len(inv_index)} unique 4-grams).")

        print("      Searching & verifying remaining Source volumes...")
        t3 = time.time()
        extra_matches = 0
        for src in unmatched_sources:
            counts = defaultdict(int)
            for sh in src["shingles_4"]:
                mids = inv_index.get(sh)
                if mids and len(mids) <= 10:
                    for mid in mids:
                        counts[mid] += 1
            if not counts:
                continue
            top_cands = sorted(counts.items(), key=lambda x: x[1], reverse=True)[:3]
            best_mid = None
            best_score = 0.0
            for cand_mid, _ in top_cands:
                score = verify_source_against_epub(src, masaha_epubs[cand_mid], epub_cache)
                if score > best_score:
                    best_score = score
                    best_mid = cand_mid
                if best_score >= 85.0:
                    break
            if best_mid and best_score >= MATCH_THRESHOLD:
                matched_results.append((src, best_mid, best_score))
                extra_matches += 1
        print(f"      Additional matches found via shingle index: {extra_matches} ({time.time()-t3:.1f}s)")

    matched_results.sort(key=lambda x: (x[0]["book_id"], x[0]["part_id"]))

    seen_mids = {}
    for src, mid, score in matched_results:
        if mid not in seen_mids or score > seen_mids[mid][2]:
            seen_mids[mid] = (src, mid, score)
    final_matches = sorted(seen_mids.values(), key=lambda x: (x[0]["book_id"], x[0]["part_id"]))

    print(f"[5/5] Isolating {len(final_matches)} matched Masaha EPUB + PDF pairs into: {OUT_DIR}")
    os.makedirs(OUT_DIR, exist_ok=True)
    for old_f in os.listdir(OUT_DIR):
        old_p = os.path.join(OUT_DIR, old_f)
        if os.path.isfile(old_p):
            try:
                os.remove(old_p)
            except Exception:
                pass

    excel_rows = []
    with_masaha_pdf = 0
    without_pdf = 0

    for seq_num, (src, mid, score) in enumerate(final_matches, 1):
        m_info = masaha_meta.get(mid, {})
        m_title = m_info.get("title") or src["book_name"]
        m_joze = m_info.get("joze") or src["vol_label"]
        safe_title = sanitize_filename(m_title)
        vol_suffix = f"_ج{sanitize_filename(m_joze, 15)}" if m_joze else ""
        base_out_name = f"{seq_num:04d} - {safe_title}{vol_suffix}"

        orig_epub = masaha_epubs[mid]
        orig_pdf = masaha_pdfs.get(mid, "")

        iso_epub = os.path.join(OUT_DIR, base_out_name + ".epub")
        shutil.copy2(orig_epub, iso_epub)

        iso_pdf = ""
        pdf_status = "متوفر (مساحة حرة)"
        if orig_pdf and os.path.exists(orig_pdf):
            iso_pdf = os.path.join(OUT_DIR, base_out_name + ".pdf")
            shutil.copy2(orig_pdf, iso_pdf)
            with_masaha_pdf += 1
        else:
            pdf_status = "غير متوفر في مساحة حرة"
            without_pdf += 1

        excel_rows.append({
            "seq": f"{seq_num:04d}",
            "mid": mid,
            "src_bid": src["book_id"],
            "src_pid": src["part_id"],
            "m_title": m_title,
            "src_title": src["book_name"],
            "joze": m_joze or "كامل",
            "author": m_info.get("author") or src["author"] or "غير محدد",
            "category": m_info.get("category") or src["category"] or "غير محدد",
            "score": score,
            "m_pages": m_info.get("pages") or 0,
            "src_pages": src["pages_count"],
            "pdf_status": pdf_status,
            "iso_epub": iso_epub,
            "iso_pdf": iso_pdf or "—",
            "orig_epub": orig_epub,
            "orig_pdf": orig_pdf or "—",
            "src_docx": src["docx_path"],
            "m_url": m_info.get("url") or f"https://www.masaha.org/book/{mid}",
        })

    # Generate Excel Report
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "الكتب المتشابهة المعزولة"
    ws.views.sheetView[0].rightToLeft = True

    headers = [
        "الرقم التسلسلي",
        "معرف مساحة حرة (ID)",
        "معرف كتاب المصدر",
        "معرف جزء المصدر",
        "اسم الكتاب (مساحة حرة)",
        "اسم الكتاب (المصدر)",
        "الجزء",
        "المؤلف",
        "التصنيف",
        "نسبة التطابق (%)",
        "صفحات مساحة حرة",
        "صفحات المصدر",
        "حالة PDF",
        "مسار EPUB المعزول المرقم",
        "مسار PDF المعزول المرقم",
        "مسار EPUB الأصلي (مساحة حرة)",
        "مسار PDF الأصلي (مساحة حرة)",
        "مسار DOCX المصدر",
        "رابط مساحة حرة",
    ]
    ws.append(headers)

    hdr_fill = PatternFill(start_color="1F4E78", end_color="1F4E78", fill_type="solid")
    hdr_font = Font(name="Arial", size=11, bold=True, color="FFFFFF")
    thin_border = Border(
        left=Side(style='thin', color='D9D9D9'),
        right=Side(style='thin', color='D9D9D9'),
        top=Side(style='thin', color='D9D9D9'),
        bottom=Side(style='thin', color='D9D9D9')
    )

    for col_idx in range(1, len(headers) + 1):
        c = ws.cell(row=1, column=col_idx)
        c.fill = hdr_fill
        c.font = hdr_font
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        c.border = thin_border
    ws.row_dimensions[1].height = 28

    green_fill = PatternFill(start_color="E2EFDA", end_color="E2EFDA", fill_type="solid")
    yellow_fill = PatternFill(start_color="FFF2CC", end_color="FFF2CC", fill_type="solid")

    for r_idx, r in enumerate(excel_rows, start=2):
        row_vals = [
            r["seq"], r["mid"], r["src_bid"], r["src_pid"],
            r["m_title"], r["src_title"], r["joze"], r["author"], r["category"],
            r["score"], r["m_pages"], r["src_pages"], r["pdf_status"],
            r["iso_epub"], r["iso_pdf"], r["orig_epub"], r["orig_pdf"], r["src_docx"], r["m_url"]
        ]
        ws.append(row_vals)
        fill = green_fill if r["score"] >= 90.0 else yellow_fill
        for c_idx in range(1, len(headers) + 1):
            cell = ws.cell(row=r_idx, column=c_idx)
            cell.font = Font(name="Arial", size=10)
            cell.border = thin_border
            if c_idx in (1, 2, 3, 4, 7, 10, 11, 12, 13):
                cell.alignment = Alignment(horizontal="center", vertical="center")
            else:
                cell.alignment = Alignment(horizontal="right", vertical="center")
            if c_idx == 10:
                cell.fill = fill
                cell.font = Font(name="Arial", size=10, bold=True)

    col_widths = [14, 18, 16, 16, 35, 35, 10, 26, 22, 16, 16, 14, 22, 55, 55, 55, 55, 55, 38]
    for i, w in enumerate(col_widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = f"A1:{get_column_letter(len(headers))}{len(excel_rows) + 1}"

    ws_sum = wb.create_sheet(title="ملخص الإحصائيات")
    ws_sum.views.sheetView[0].rightToLeft = True
    summary_data = [
        ("البيان", "القيمة"),
        ("إجمالي كتب مساحة حرة (EPUB)", len(masaha_epubs)),
        ("إجمالي مجلدات المصدر المفحوصة", len(sources)),
        ("الكتب المتشابهة المعزولة (تطابق >= 80%)", len(final_matches)),
        ("المعزولة مع PDF مساحة حرة", with_masaha_pdf),
        ("المعزولة بدون PDF في مساحة حرة", without_pdf),
        ("متوسط نسبة التطابق (%)", round(sum(r["score"] for r in excel_rows) / len(excel_rows), 2) if excel_rows else 0),
        ("مجلد العزل المرقم", OUT_DIR),
        ("زمن التنفيذ (بالثواني)", round(time.time() - t_start, 2)),
    ]
    for idx, (k_lbl, v_val) in enumerate(summary_data, 1):
        ws_sum.append([k_lbl, v_val])
        c1 = ws_sum.cell(row=idx, column=1)
        c2 = ws_sum.cell(row=idx, column=2)
        c1.border = thin_border
        c2.border = thin_border
        if idx == 1:
            c1.fill = hdr_fill; c1.font = hdr_font
            c2.fill = hdr_fill; c2.font = hdr_font
        else:
            c1.font = Font(name="Arial", size=11, bold=True)
            c2.font = Font(name="Arial", size=11)
    ws_sum.column_dimensions["A"].width = 40
    ws_sum.column_dimensions["B"].width = 60

    wb.save(OUT_EXCEL)

    print("=" * 70)
    print(f"DONE in {time.time() - t_start:.1f}s!")
    print(f"Total matched & isolated: {len(final_matches)} books (EPUB + PDF: {with_masaha_pdf})")
    print(f"Isolated folder: {OUT_DIR}")
    print(f"Excel report:    {OUT_EXCEL}")
    print("=" * 70)


if __name__ == "__main__":
    main()
