# -*- coding: utf-8 -*-
"""
Fetch & Verify Accurate PDFs from Archive.org and Alfeker (?fk_dl=)
for the remaining 109 non-Masaha books where the old local PDF was inaccurate.
"""

import os
import re
import json
import time
import shutil
import difflib
import requests
import urllib3
import pymupdf as fitz
import openpyxl
from openpyxl.styles import PatternFill

import sys
sys.path.insert(0, r"d:\01_Projects\mobile\nots\tools")
from find_accurate_alternatives import (
    OUT_ALT_DIR, OUT_ALT_EXCEL, AF_CATALOG_PATH, MATCHING_DB_JSON,
    search_alfeker_candidates, parse_vol_num, sanitize_filename, clean_title
)

urllib3.disable_warnings()
HEADERS = {'User-Agent': 'Mozilla/5.0'}


def search_archive_pdfs(book_name: str, author: str, vol_num: int):
    """Search Archive.org for PDF files matching book title and volume number."""
    c_title = clean_title(book_name)
    # Build clean search query
    q_words = c_title.split()[:5]
    if author and author != "غير محدد":
        a_words = [w for w in clean_title(author).split() if w not in ("الشيخ", "السيد", "بن", "ابي", "محمد", "علي")][:2]
        q_words.extend(a_words)
    query = " ".join(q_words)

    urls = []
    try:
        r = requests.get(
            "https://archive.org/advancedsearch.php",
            params={"q": f"{query} AND mediatype:texts", "fl[]": "identifier,title", "rows": 25, "output": "json"},
            timeout=15,
            verify=False,
        )
        if r.status_code != 200:
            return urls
        docs = r.json().get("response", {}).get("docs", [])
        scored = []
        for d in docs:
            ident = d.get("identifier", "")
            t = str(d.get("title") or "")
            if "فارسي" in t or "ترجمة" in t or "مكتبه" in t or "موسوعة" in t:
                continue
            sim = difflib.SequenceMatcher(None, c_title, clean_title(t)).ratio()
            if c_title in clean_title(t):
                sim = max(sim, 0.85)
            # Check volume number match in title or identifier
            vol_bonus = 0.0
            if vol_num > 0:
                nums_in_t = [int(x) for x in re.findall(r'\d+', t)]
                if vol_num in nums_in_t:
                    vol_bonus = 0.35
                elif any(x in (f"_{vol_num}_", f"-{vol_num}", f"0{vol_num}", f"{vol_num:02d}") for x in [ident]):
                    vol_bonus = 0.25
                elif nums_in_t:
                    vol_bonus = -0.30
            if sim + vol_bonus >= 0.60:
                scored.append((sim + vol_bonus, ident, t))

        scored.sort(key=lambda x: x[0], reverse=True)
        for _, ident, _ in scored[:4]:
            try:
                meta = requests.get(f"https://archive.org/metadata/{ident}/files", timeout=12, verify=False).json()
                pdf_files = [
                    f["name"] for f in meta.get("result", [])
                    if f.get("name", "").lower().endswith(".pdf")
                    and not f.get("name", "").lower().endswith("_text.pdf")
                    and int(f.get("size", 0) or 0) > 100000
                ]
                # If multiple PDFs inside one item (e.g. 01.pdf, 02.pdf, ...), pick matching volume
                if len(pdf_files) > 1 and vol_num > 0:
                    matched_f = [
                        fn for fn in pdf_files
                        if re.search(rf'(?<!\d)0?{vol_num}(?!\d)', fn)
                    ]
                    if matched_f:
                        pdf_files = matched_f + [fn for fn in pdf_files if fn not in matched_f][:1]
                for fn in pdf_files[:2]:
                    urls.append(f"https://archive.org/download/{ident}/{requests.utils.quote(fn)}")
            except Exception:
                pass
    except Exception:
        pass
    return urls


def get_alfeker_fk_dl_links(af_id: int, vol_num: int):
    """Test ?fk_dl={af_id}&i={idx} endpoints for direct PDF downloads."""
    urls = []
    # Try index matching vol_num-1 first, then 0..2
    indices = []
    if vol_num > 0:
        indices.append(vol_num - 1)
    for i in (0, 1, 2):
        if i not in indices:
            indices.append(i)
    for idx in indices[:3]:
        u = f"https://alfeker.net/?fk_dl={af_id}&i={idx}"
        try:
            r = requests.head(u, headers=HEADERS, allow_redirects=True, timeout=10, verify=False)
            ctype = r.headers.get("Content-Type", "").lower()
            clen = int(r.headers.get("Content-Length", 0) or 0)
            if r.status_code == 200 and ("pdf" in ctype or r.url.lower().endswith(".pdf")) and clen > 100000:
                urls.append(r.url)
        except Exception:
            pass
    return urls


def download_and_check_pdf(url: str, db_pages: int, out_pdf: str) -> tuple[bool, int]:
    tmp = out_pdf + ".tmp.pdf"
    try:
        r = requests.get(url, headers=HEADERS, stream=True, verify=False, timeout=90, allow_redirects=True)
        if r.status_code != 200:
            return False, 0
        if "html" in r.headers.get("Content-Type", "").lower():
            return False, 0
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(65536):
                if chunk:
                    f.write(chunk)
        if os.path.exists(tmp) and os.path.getsize(tmp) > 50000:
            doc = fitz.open(tmp)
            n_pdf = doc.page_count
            doc.close()
            if n_pdf >= 15 and (db_pages == 0 or 0.55 <= n_pdf / db_pages <= 1.85):
                os.replace(tmp, out_pdf)
                return True, n_pdf
    except Exception:
        pass
    if os.path.exists(tmp):
        try:
            os.remove(tmp)
        except Exception:
            pass
    return False, 0


def main():
    t0 = time.time()
    print("=" * 72)
    print("FETCHING ACCURATE ARCHIVE.ORG & ALFEKER PDFS FOR REMAINING 109 VOLUMES")
    print("=" * 72)

    with open(AF_CATALOG_PATH, "r", encoding="utf-8") as f:
        af_catalog = json.load(f)
    with open(MATCHING_DB_JSON, "r", encoding="utf-8") as f:
        mdb = json.load(f)

    wb = openpyxl.load_workbook(OUT_ALT_EXCEL)
    ws = wb["باقي الكتب والبدائل الدقيقة"]

    rows_list = list(ws.iter_rows(min_row=2))
    todo_rows = [r for r in rows_list if r[8].value == "غير دقيق"]
    print(f"Found {len(todo_rows)} volumes needing verified PDFs...")

    blue_fill = PatternFill(start_color="D9E1F2", end_color="D9E1F2", fill_type="solid")
    downloaded = 0
    failed = 0

    for idx, row in enumerate(todo_rows, 1):
        seq = str(row[0].value)
        key = str(row[1].value)
        b_name = str(row[2].value)
        vol_label = str(row[3].value)
        author = str(row[4].value or "")
        db_pages = int(row[6].value or 0)
        vol_num = parse_vol_num(vol_label)

        safe_t = sanitize_filename(b_name)
        v_suf = f"_ج{sanitize_filename(vol_label, 12)}" if vol_label and vol_label != "كامل" else ""
        out_pdf = os.path.join(OUT_ALT_DIR, f"{seq} - {safe_t}{v_suf}.pdf")
        out_docx = os.path.join(OUT_ALT_DIR, f"{seq} - {safe_t}{v_suf}.docx")

        # 1. Search Archive.org first (exact volume matching)
        cand_urls = [(u, "Archive.org") for u in search_archive_pdfs(b_name, author, vol_num)]

        # 2. Search Alfeker ?fk_dl= links
        af_cands = search_alfeker_candidates(b_name, af_catalog)
        for af_b in af_cands[:2]:
            for u in get_alfeker_fk_dl_links(af_b["id"], vol_num):
                cand_urls.append((u, "شبكة الفكر (Alfeker)"))

        ok = False
        used_url = ""
        used_src = ""
        n_new = 0
        for u, src_lbl in cand_urls[:4]:
            ok, n_new = download_and_check_pdf(u, db_pages, out_pdf)
            if ok:
                used_url = u
                used_src = src_lbl
                break

        if ok:
            downloaded += 1
            row[7].value = n_new
            row[8].value = "بديل مؤكد ومحمل"
            row[8].fill = blue_fill
            row[14].value = f"{used_src} ({n_new} ص)"
            row[15].value = used_url
            row[16].value = out_pdf

            src_docx = mdb.get(key, {}).get("docx_path") or ""
            if src_docx and os.path.exists(src_docx) and not os.path.exists(out_docx):
                shutil.copy2(src_docx, out_docx)
        else:
            failed += 1

        if idx % 10 == 0 or idx == len(todo_rows):
            print(f"[{idx}/{len(todo_rows)}] Downloaded & verified: {downloaded} | Unavailable: {failed}")

    wb.save(OUT_ALT_EXCEL)
    print("=" * 72)
    print(f"DONE in {time.time()-t0:.1f}s | Downloaded: {downloaded} | Unavailable: {failed}")
    print("=" * 72)


if __name__ == "__main__":
    main()
