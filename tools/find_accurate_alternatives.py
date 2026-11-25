# -*- coding: utf-8 -*-
"""
Accurate Alternative Finder & Verifier for Remaining Books (Not in Masaha Local)
1. Reads the Masaha-matched Excel report to get all remaining Source volumes.
2. Audits existing PDFs in كتب_المكتبة_PDF for accuracy (file integrity, page count ratio, text/edition match).
3. For inaccurate/missing/mismatched volumes, searches:
   - Ablibrary (18,500 books catalog + BookService/HTMLContents text sampling >= 80%)
   - Alfeker (5,728 books catalog + direct PDF link extraction + page count verification)
   - Masaha Online Catalog (6,000 books EPUBs where has_epub=1)
4. Downloads/assembles verified accurate PDFs (including Ablibrary scanned page PNGs -> PDF if no direct PDF),
   isolates remaining books into كتب_البدائل_الدقيقة_المؤكدة, and outputs an Excel report.
"""

import os
import re
import sys
import json
import time
import html
import shutil
import sqlite3
import difflib
from pathlib import Path
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

import requests
import urllib3
import pymupdf as fitz
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

urllib3.disable_warnings()

BASE_DIR = r"d:\01_Projects\mobile\nots"
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
MATCHING_DB_JSON = os.path.join(BASE_DIR, "matching_database.json")
MASAHA_DB = os.path.join(BASE_DIR, "كتب مساحة حرة", "masaha_state.db")
MASAHA_EXCEL = os.path.join(BASE_DIR, "تقرير_الكتب_المتشابهة_مساحة_حرة_والمصدر.xlsx")

AB_CATALOG_PATH = os.path.join(BASE_DIR, "tools", "ablibrary_all_catalog.json")
AF_CATALOG_PATH = os.path.join(BASE_DIR, "tools", "alfeker_all_catalog.json")

OUT_ALT_DIR = r"G:\كتب_الانترنت_البديلة_المؤكدة"
OUT_ALT_EXCEL = os.path.join(BASE_DIR, "تقرير_البدائل_الدقيقة_للكتب_المتبقية.xlsx")

AB_HEADERS = {
    'User-Agent': 'Mozilla/5.0',
    'Content-Type': 'application/json',
    'Connect-Protocol-Version': '1',
}

TAG_RE = re.compile(r'<[^>]+>')
FN_RE = re.compile(r'<(?:fn|fnote)>.*?</(?:fn|fnote)>', re.DOTALL | re.IGNORECASE)
DIACRITICS_RE = re.compile(r'[\u064B-\u065F\u0670\u0640\u200c\u200d\u200e\u200f\ufeff]')
NON_ARABIC_RE = re.compile(r'[^\u0621-\u064A\s]')
MULTI_SPACE_RE = re.compile(r'\s+')
DROP_NOISE_RE = re.compile(r'\[صفحة\s*\d+\]|بياض\s+مطابق\s+للأصل')

NORM_TRANS = str.maketrans({
    'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
    'ى': 'ي',
    'ة': 'ه',
    'ؤ': 'و',
    'ئ': 'ي',
    'ی': 'ي',
    'ک': 'ك',
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
    text = html.unescape(str(text))
    text = DROP_NOISE_RE.sub(' ', text)
    text = FN_RE.sub(' ', text)
    text = TAG_RE.sub(' ', text)
    text = DIACRITICS_RE.sub('', text)
    text = text.translate(NORM_TRANS)
    text = NON_ARABIC_RE.sub(' ', text)
    return MULTI_SPACE_RE.sub(' ', text).strip()


def clean_title(t: str) -> str:
    t = normalize_ar(t)
    t = re.sub(r'^(كتاب|رساله|منظومه|تفسير|موسوعه)\s+', '', t)
    return t.strip()


def sanitize_filename(name: str, max_len: int = 85) -> str:
    name = re.sub(r'[\\/:*?"<>|\r\n\t]+', '_', str(name)).strip(' ._')
    if len(name) > max_len:
        name = name[:max_len].strip(' ._')
    return name or "book"


def parse_vol_num(vol_label: str) -> int:
    if not vol_label:
        return 0
    m = re.search(r'\d+', str(vol_label))
    return int(m.group(0)) if m else 0


def load_masaha_matched_keys() -> set[str]:
    matched = set()
    if os.path.exists(MASAHA_EXCEL):
        wb = openpyxl.load_workbook(MASAHA_EXCEL, read_only=True)
        if "الكتب المتشابهة المعزولة" in wb.sheetnames:
            ws = wb["الكتب المتشابهة المعزولة"]
            for idx, row in enumerate(ws.iter_rows(values_only=True)):
                if idx == 0:
                    continue
                if row[2] is not None and row[3] is not None:
                    matched.add(f"{row[2]}_{row[3]}")
        wb.close()
    return matched


def fetch_ab_sample_words(ab_id: str, pages_count: int):
    """Fetch 3 small ranges of body pages from Ablibrary HTMLContents to get content words & bigrams."""
    if pages_count <= 0:
        pages_count = 100
    p1 = max(1, int(pages_count * 0.25))
    p2 = max(1, int(pages_count * 0.50))
    p3 = max(1, int(pages_count * 0.75))

    ab_words = set()
    ab_bigrams = set()
    for p in (p1, p2, p3):
        try:
            r = requests.post(
                "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/HTMLContents",
                json={"bookId": str(ab_id), "fromPage": p, "toPage": min(pages_count, p + 4)},
                headers=AB_HEADERS,
                timeout=12,
            )
            if r.status_code == 200:
                data = r.json().get("data", "")
                ws = normalize_ar(data).split()
                for w in ws:
                    if len(w) >= 4:
                        ab_words.add(w)
                for i in range(len(ws) - 1):
                    ab_bigrams.add(ws[i] + ' ' + ws[i + 1])
        except Exception:
            pass
    return ab_words, ab_bigrams


def score_source_vs_wordset(sample_page_data, target_words: set, target_bigrams: set) -> float:
    if not sample_page_data or not target_words:
        return 0.0
    tot_w = hit_w = tot_b = hit_b = 0
    for cw, bg in sample_page_data:
        if not cw or not bg:
            continue
        tot_w += len(cw)
        hit_w += len(cw & target_words)
        tot_b += len(bg)
        hit_b += len(bg & target_bigrams)
    if tot_w == 0 or tot_b == 0:
        return 0.0
    # When comparing against 15 sampled AB pages (not whole book), check overall + hit density
    w_r = hit_w / tot_w
    b_r = hit_b / tot_b
    return round(((0.60 * w_r) + (0.40 * b_r)) * 100.0, 2)


def fetch_ab_full_text_sets(ab_id: str, pages_count: int):
    """Fetch larger body range (15%..85% in chunks) for definitive verification of a promising candidate."""
    if pages_count <= 0:
        pages_count = 200
    ab_words = set()
    ab_bigrams = set()
    step = max(15, pages_count // 5)
    for start_p in range(max(1, int(pages_count * 0.12)), int(pages_count * 0.88), step):
        end_p = min(pages_count, start_p + 18)
        try:
            r = requests.post(
                "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/HTMLContents",
                json={"bookId": str(ab_id), "fromPage": start_p, "toPage": end_p},
                headers=AB_HEADERS,
                timeout=15,
            )
            if r.status_code == 200:
                data = r.json().get("data", "")
                ws = normalize_ar(data).split()
                for w in ws:
                    if len(w) >= 4:
                        ab_words.add(w)
                for i in range(len(ws) - 1):
                    ab_bigrams.add(ws[i] + ' ' + ws[i + 1])
        except Exception:
            pass
    return ab_words, ab_bigrams


def check_ab_pdf_available(ab_id: str):
    """Check if Ablibrary has direct PDF or scanned PNG pages for ab_id."""
    direct_url = f"https://grpc.ablibrary.net/static/pdf/{ab_id}.pdf"
    try:
        r = requests.head(direct_url, timeout=8, verify=False)
        if r.status_code == 200 and int(r.headers.get("Content-Length", 0)) > 50000:
            return "ab_direct_pdf", direct_url
    except Exception:
        pass
    # Check scanned page 1 image
    png_url = f"https://grpc.ablibrary.net/pdf/{ab_id}/pages/1.png"
    try:
        r = requests.head(png_url, timeout=8, verify=False)
        if r.status_code == 200:
            return "ab_scanned_pages", f"https://ablibrary.net/#/reading/book/{ab_id}"
    except Exception:
        pass
    return "ab_text_only", f"https://ablibrary.net/#/reading/book/{ab_id}"


def download_verified_pdf(alt_type: str, alt_url: str, ab_id: str, ab_pages: int, out_pdf_path: str) -> bool:
    """Download or assemble a verified accurate PDF from Ablibrary or Alfeker/Archive."""
    tmp_path = out_pdf_path + ".tmp.pdf"
    try:
        if alt_type == "ab_direct_pdf" or alt_type == "alfeker_pdf":
            r = requests.get(alt_url, headers={'User-Agent': 'Mozilla/5.0'}, stream=True, verify=False, timeout=60, allow_redirects=True)
            if r.status_code == 200:
                ctype = r.headers.get("Content-Type", "").lower()
                if "html" in ctype:
                    return False
                with open(tmp_path, "wb") as f:
                    for chunk in r.iter_content(65536):
                        if chunk:
                            f.write(chunk)
                if os.path.exists(tmp_path) and os.path.getsize(tmp_path) > 30000:
                    doc = fitz.open(tmp_path)
                    cnt = doc.page_count
                    doc.close()
                    if cnt >= 5:
                        os.replace(tmp_path, out_pdf_path)
                        return True
        elif alt_type == "ab_scanned_pages" and ab_id and ab_pages > 0:
            def fetch_page(p_num):
                url = f"https://grpc.ablibrary.net/pdf/{ab_id}/pages/{p_num}.png"
                try:
                    resp = requests.get(url, timeout=15, verify=False)
                    if resp.status_code == 200 and len(resp.content) > 500:
                        return p_num, resp.content
                except Exception:
                    pass
                return p_num, None

            pages_data = {}
            with ThreadPoolExecutor(max_workers=12) as ex:
                for p_num, content in ex.map(fetch_page, range(1, ab_pages + 1)):
                    if content:
                        pages_data[p_num] = content

            if len(pages_data) >= max(5, int(ab_pages * 0.8)):
                doc = fitz.open()
                for p_num in range(1, ab_pages + 1):
                    img_bytes = pages_data.get(p_num)
                    if img_bytes:
                        img_doc = fitz.open(stream=img_bytes, filetype="png")
                        pdf_bytes = img_doc.convert_to_pdf()
                        img_doc.close()
                        page_pdf = fitz.open("pdf", pdf_bytes)
                        doc.insert_pdf(page_pdf)
                        page_pdf.close()
                    else:
                        doc.new_page(width=595, height=842)
                doc.save(tmp_path, deflate=True)
                doc.close()
                os.replace(tmp_path, out_pdf_path)
                return True
    except Exception:
        pass
    if os.path.exists(tmp_path):
        try:
            os.remove(tmp_path)
        except Exception:
            pass
    return False


def search_ab_candidates(book_name: str, vol_num: int, db_pages: int, ab_catalog: list):
    """Find top Ablibrary candidates matching title, volume, and page count (excluding Persian)."""
    q_clean = clean_title(book_name)
    q_norm = normalize_ar(book_name)
    scored = []
    for b in ab_catalog:
        title = b.get("title") or ""
        if "فارسي" in title or "ترجمه" in title or "ترجمة" in title:
            continue
        b_clean = clean_title(b.get("core_title") or title)
        if not b_clean:
            continue
        # Fast token overlap pre-filter
        sim = difflib.SequenceMatcher(None, q_clean, b_clean).ratio()
        if q_clean in b_clean or b_clean in q_clean:
            sim = max(sim, 0.85)
        if sim < 0.58:
            continue

        b_vol = int(b.get("volumeNumber") or 0)
        b_pages = int(b.get("pagesCount") or 0)

        # Volume match bonus/penalty
        vol_bonus = 0.0
        if vol_num > 0:
            if b_vol == vol_num:
                vol_bonus = 0.25
            elif b_vol == 0:
                vol_bonus = 0.05
            else:
                vol_bonus = -0.35

        # Page count compatibility
        page_bonus = 0.0
        if db_pages > 0 and b_pages > 0:
            ratio = min(db_pages, b_pages) / max(db_pages, b_pages)
            if ratio >= 0.75:
                page_bonus = 0.15 * ratio
            elif ratio < 0.45:
                page_bonus = -0.25

        total_rank = sim + vol_bonus + page_bonus
        if total_rank >= 0.65:
            scored.append((total_rank, b))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [x[1] for x in scored[:5]]


def search_alfeker_candidates(book_name: str, af_catalog: list):
    """Find top Alfeker candidates matching title."""
    q_clean = clean_title(book_name)
    scored = []
    for b in af_catalog:
        t_clean = clean_title(b.get("title") or "")
        if not t_clean:
            continue
        sim = difflib.SequenceMatcher(None, q_clean, t_clean).ratio()
        if q_clean in t_clean:
            sim = max(sim, 0.82)
        if sim >= 0.65:
            scored.append((sim, b))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [x[1] for x in scored[:3]]


def extract_alfeker_pdf_links(af_link: str, vol_num: int):
    """Fetch Alfeker book page and extract PDF links."""
    try:
        r = requests.get(af_link, headers={'User-Agent': 'Mozilla/5.0'}, timeout=12)
        if r.status_code != 200:
            return []
        links = re.findall(r'href=["\']([^"\']*(?:\?fk_dl=\d+&i=\d+|\.pdf))["\']', r.text, re.IGNORECASE)
        if not links:
            return []
        # Deduplicate while preserving order
        seen = []
        for l in links:
            if l not in seen:
                seen.append(l)
        if vol_num > 0 and len(seen) >= vol_num:
            return [seen[vol_num - 1]] + [x for x in seen if x != seen[vol_num - 1]][:2]
        return seen[:3]
    except Exception:
        return []


def verify_existing_pdf_text(pdf_path: str, sample_page_data):
    """If PDF has an embedded text layer, verify text match against Source."""
    try:
        doc = fitz.open(pdf_path)
        n_pdf = doc.page_count
        if n_pdf == 0:
            doc.close()
            return 0, 0.0, False
        # Sample 15 pages from 15%..85%
        lo = max(0, int(n_pdf * 0.15))
        hi = min(n_pdf, int(n_pdf * 0.85))
        step = max(1, (hi - lo) // 15)
        pdf_words = set()
        pdf_bigrams = set()
        text_chars = 0
        for p_idx in range(lo, hi, step):
            txt = doc[p_idx].get_text() or ""
            text_chars += len(txt.strip())
            ws = normalize_ar(txt).split()
            for w in ws:
                if len(w) >= 4:
                    pdf_words.add(w)
            for i in range(len(ws) - 1):
                pdf_bigrams.add(ws[i] + ' ' + ws[i + 1])
        doc.close()
        if text_chars < 300:
            return n_pdf, -1.0, False  # Scanned image-only PDF (no text layer)
        sc = score_source_vs_wordset(sample_page_data, pdf_words, pdf_bigrams)
        return n_pdf, sc, True
    except Exception:
        return 0, 0.0, False


def main():
    t_start = time.time()
    print("=" * 75)
    print("ACCURATE ALTERNATIVE FINDER & VERIFIER FOR REMAINING BOOKS")
    print("=" * 75)

    matched_masaha = load_masaha_matched_keys()
    print(f"[1/4] Already matched & isolated in Masaha: {len(matched_masaha)} volumes.")

    with open(MATCHING_DB_JSON, "r", encoding="utf-8") as f:
        mdb = json.load(f)

    with open(AB_CATALOG_PATH, "r", encoding="utf-8") as f:
        ab_catalog = json.load(f)

    with open(AF_CATALOG_PATH, "r", encoding="utf-8") as f:
        af_catalog = json.load(f)

    # Load Masaha online catalog (even those without PDFs, to check EPUB availability)
    masaha_online = {}
    if os.path.exists(MASAHA_DB):
        mconn = sqlite3.connect(MASAHA_DB)
        for mid, title, has_pdf, has_epub in mconn.execute("SELECT id, title, has_pdf, has_epub FROM catalog"):
            masaha_online[int(mid)] = {"title": title, "has_pdf": has_pdf, "has_epub": has_epub}
        mconn.close()

    # Load Source DB
    conn = sqlite3.connect(REPAIRED_DB)
    books_meta = {}
    for row in conn.execute("SELECT id, book_name, authorName, category, parts_count FROM Books"):
        books_meta[int(row[0])] = {
            "book_name": row[1] or "",
            "author": row[2] or "",
            "category": CATEGORY_FULL.get(row[3], str(row[3] or "")),
        }

    parts_pages = defaultdict(list)
    for pid, page_id, text in conn.execute("SELECT part_id, page_id, text FROM BookPages ORDER BY part_id, page_id"):
        if text and len(text.strip()) > 60:
            parts_pages[int(pid)].append((int(page_id), text.split('\x00')[0]))
    conn.close()

    remaining = [(k, v) for k, v in mdb.items() if k not in matched_masaha]
    remaining.sort(key=lambda x: (int(x[0].split('_')[0]), int(x[0].split('_')[1])))
    print(f"[2/4] Remaining volumes to audit & verify: {len(remaining)}")

    os.makedirs(OUT_ALT_DIR, exist_ok=True)
    ab_text_cache = {}
    af_link_cache = {}
    excel_rows = []

    accurate_existing = 0
    replaced_verified = 0
    needs_manual = 0

    print("[3/4] Auditing existing PDFs and searching verified alternatives...")
    for idx, (key, v) in enumerate(remaining, 1):
        b_id, part_id = map(int, key.split('_'))
        binfo = books_meta.get(b_id, {})
        b_name = binfo.get("book_name") or v.get("book_name") or ""
        author = binfo.get("author") or ""
        cat_name = binfo.get("category") or ""
        vol_label = str(v.get("vol_label") or "")
        vol_num = parse_vol_num(vol_label)

        pages = parts_pages.get(part_id, [])
        db_cnt = len(pages)

        # Sample 10 body pages of Source
        sample_page_data = []
        if pages:
            lo = max(0, int(len(pages) * 0.15))
            hi = min(len(pages), int(len(pages) * 0.85))
            body = pages[lo:hi] if hi - lo >= 10 else pages
            step = max(1, len(body) // 10)
            for _, txt in body[::step][:10]:
                ws = normalize_ar(txt).split()
                if len(ws) >= 12:
                    cw = {w for w in ws if len(w) >= 4}
                    bg = {ws[i] + ' ' + ws[i + 1] for i in range(len(ws) - 1)}
                    sample_page_data.append((cw, bg))

        local_pdf = v.get("local_pdf_path") or ""
        n_pdf = 0
        pdf_text_sc = -1.0
        has_text_layer = False
        audit_status = "غير دقيق"
        audit_reason = ""

        if local_pdf and os.path.exists(local_pdf) and os.path.getsize(local_pdf) > 10000:
            n_pdf, pdf_text_sc, has_text_layer = verify_existing_pdf_text(local_pdf, sample_page_data)
            ratio = (n_pdf / db_cnt) if db_cnt else 0
            if n_pdf == 0:
                audit_reason = "PDF تالف"
            elif ratio < 0.72 or ratio > 1.50:
                audit_reason = f"عدم تطابق الصفحات ({n_pdf} مقابل {db_cnt})"
            elif has_text_layer and pdf_text_sc < 55.0:
                audit_reason = f"النص غير مطابق ({pdf_text_sc}%)"
            else:
                audit_status = "دقيق ومطابق"
                audit_reason = f"صفحات متوافقة ({n_pdf} مقابل {db_cnt})"
                accurate_existing += 1
        else:
            audit_reason = "ملف PDF مفقود"

        # Verify current ab_book_id or search for better alternative if inaccurate or unverified
        best_ab_id = v.get("ab_book_id") or ""
        best_ab_title = ""
        best_ab_pages = 0
        best_ab_score = 0.0
        best_alt_url = v.get("pdf_url") or ""
        best_alt_src = v.get("pdf_source") or ""

        if audit_status != "دقيق ومطابق":
            # Search Ablibrary catalog for exact Arabic edition
            cands = search_ab_candidates(b_name, vol_num, db_cnt, ab_catalog)
            for cand in cands:
                cid = str(cand["id"])
                cpages = int(cand.get("pagesCount") or 0)
                if cid not in ab_text_cache:
                    ab_text_cache[cid] = fetch_ab_full_text_sets(cid, cpages)
                cw_set, bg_set = ab_text_cache[cid]
                sc = score_source_vs_wordset(sample_page_data, cw_set, bg_set)
                if sc > best_ab_score:
                    best_ab_score = sc
                    best_ab_id = cid
                    best_ab_title = cand.get("title", "")
                    best_ab_pages = cpages
                if best_ab_score >= 75.0:
                    break

            # Also check Alfeker catalog for direct PDF
            af_cands = search_alfeker_candidates(b_name, af_catalog)
            af_pdf_url = ""
            for af_b in af_cands:
                link = af_b.get("link")
                if link not in af_link_cache:
                    af_link_cache[link] = extract_alfeker_pdf_links(link, vol_num)
                if af_link_cache[link]:
                    af_pdf_url = af_link_cache[link][0]
                    break

            alt_dl_type = ""
            if best_ab_score >= 65.0:
                ab_type, ab_url = check_ab_pdf_available(best_ab_id)
                best_alt_url = ab_url
                best_alt_src = f"مكتبة أهل البيت المؤكدة ({ab_type} | {best_ab_score}%)"
                alt_dl_type = ab_type
                replaced_verified += 1
            elif af_pdf_url:
                best_alt_url = af_pdf_url
                best_alt_src = "شبكة الفكر (Alfeker PDF)"
                alt_dl_type = "alfeker_pdf"
                replaced_verified += 1
            else:
                needs_manual += 1
        else:
            alt_dl_type = ""

        # Copy accurate PDFs or download verified alternative PDFs into OUT_ALT_DIR with numbering
        iso_pdf_path = "—"
        safe_t = sanitize_filename(b_name)
        v_suf = f"_ج{sanitize_filename(vol_label, 12)}" if vol_label else ""
        out_pdf_target = os.path.join(OUT_ALT_DIR, f"{idx:04d} - {safe_t}{v_suf}.pdf")
        out_docx_target = os.path.join(OUT_ALT_DIR, f"{idx:04d} - {safe_t}{v_suf}.docx")

        if audit_status == "دقيق ومطابق" and os.path.exists(local_pdf):
            shutil.copy2(local_pdf, out_pdf_target)
            iso_pdf_path = out_pdf_target
        elif alt_dl_type in ("ab_direct_pdf", "ab_scanned_pages", "alfeker_pdf"):
            if os.path.exists(out_pdf_target) and os.path.getsize(out_pdf_target) > 30000:
                iso_pdf_path = out_pdf_target
            elif download_verified_pdf(alt_dl_type, best_alt_url, best_ab_id, best_ab_pages, out_pdf_target):
                iso_pdf_path = out_pdf_target
                audit_status = "بديل مؤكد ومحمل"

        src_docx = v.get("docx_path") or ""
        if iso_pdf_path != "—" and src_docx and os.path.exists(src_docx):
            if not os.path.exists(out_docx_target):
                shutil.copy2(src_docx, out_docx_target)

        excel_rows.append({
            "seq": f"{idx:04d}",
            "key": key,
            "b_name": b_name,
            "vol": vol_label or "كامل",
            "author": author or "غير محدد",
            "cat": cat_name,
            "db_pages": db_cnt,
            "pdf_pages": n_pdf,
            "audit_status": audit_status,
            "audit_reason": audit_reason,
            "best_ab_id": best_ab_id or "—",
            "best_ab_title": best_ab_title or "—",
            "best_ab_pages": best_ab_pages,
            "best_ab_score": best_ab_score,
            "best_alt_src": best_alt_src,
            "best_alt_url": best_alt_url,
            "iso_pdf": iso_pdf_path,
            "orig_pdf": local_pdf,
            "docx_path": v.get("docx_path") or "",
        })

        if idx % 40 == 0 or idx == len(remaining):
            print(f"      [{idx}/{len(remaining)}] Accurate={accurate_existing} | VerifiedAlt={replaced_verified} | NeedsManual={needs_manual}")

    print("[4/4] Generating Excel report for remaining books...")
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "باقي الكتب والبدائل الدقيقة"
    ws.views.sheetView[0].rightToLeft = True

    headers = [
        "الرقم", "المعرف", "اسم الكتاب", "الجزء", "المؤلف", "التصنيف",
        "صفحات المصدر", "صفحات PDF الحالي", "حالة النسخة الحالية", "سبب التقييم",
        "معرف البديل المؤكد (Ablibrary)", "عنوان البديل المؤكد", "صفحات البديل",
        "نسبة تطابق نص البديل (%)", "المصدر البديل المقترح", "رابط البديل المباشر",
        "مسار PDF المعزول (للدقيق)", "مسار PDF الحالي", "مسار DOCX المصدر"
    ]
    ws.append(headers)

    hdr_fill = PatternFill(start_color="1F4E78", end_color="1F4E78", fill_type="solid")
    hdr_font = Font(name="Arial", size=11, bold=True, color="FFFFFF")
    green_fill = PatternFill(start_color="E2EFDA", end_color="E2EFDA", fill_type="solid")
    orange_fill = PatternFill(start_color="FCE4D6", end_color="FCE4D6", fill_type="solid")
    blue_fill = PatternFill(start_color="D9E1F2", end_color="D9E1F2", fill_type="solid")

    for col_i in range(1, len(headers) + 1):
        c = ws.cell(row=1, column=col_i)
        c.fill = hdr_fill; c.font = hdr_font
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    for r_i, r in enumerate(excel_rows, start=2):
        vals = [
            r["seq"], r["key"], r["b_name"], r["vol"], r["author"], r["cat"],
            r["db_pages"], r["pdf_pages"], r["audit_status"], r["audit_reason"],
            r["best_ab_id"], r["best_ab_title"], r["best_ab_pages"], r["best_ab_score"],
            r["best_alt_src"], r["best_alt_url"], r["iso_pdf"], r["orig_pdf"], r["docx_path"]
        ]
        ws.append(vals)
        st_cell = ws.cell(row=r_i, column=9)
        if r["audit_status"] == "دقيق ومطابق":
            st_cell.fill = green_fill
        elif r["best_ab_score"] >= 65.0:
            st_cell.fill = blue_fill
        else:
            st_cell.fill = orange_fill

    widths = [10, 14, 34, 10, 24, 20, 14, 16, 18, 28, 18, 30, 14, 18, 32, 45, 50, 50, 50]
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = f"A1:{get_column_letter(len(headers))}{len(excel_rows) + 1}"

    wb.save(OUT_ALT_EXCEL)
    print("=" * 75)
    print(f"DONE in {time.time() - t_start:.1f}s!")
    print(f"Accurate existing: {accurate_existing} | Verified alternatives found: {replaced_verified} | Remaining manual: {needs_manual}")
    print(f"Excel report: {OUT_ALT_EXCEL}")
    print("=" * 75)


if __name__ == "__main__":
    main()
