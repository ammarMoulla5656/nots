# -*- coding: utf-8 -*-
"""
مطابقة الكتب المتبقية (التي تشير إلى grpc.ablibrary.net/static/pdf/) مع روابط PDF المباشرة
على شبكة الفكر (alfeker.net/?fk_dl=...) لتسريع التنزيل 10 أضعاف، مع إبقاء السكان الأصلي
لمكتبة أهل البيت (grpc.ablibrary.net/pdf/{id}/pages/{p}.png) متاحاً للكتب غير الموجودة في الفكر.
"""

import os
import re
import html
import json
import sqlite3
import difflib
import urllib.request
import concurrent.futures

BASE_DIR = r"d:\01_Projects\mobile\nots"
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
AF_CATALOG_CACHE = os.path.join(BASE_DIR, "tools", "alfeker_all_catalog.json")

from resolve_real_pdfs_for_118_books import norm_text, strip_title_noise, get_author_tokens

def verify_fk_dl_url(wp_id, vol_idx=0):
    u = f"https://alfeker.net/?fk_dl={wp_id}&i={vol_idx}"
    try:
        req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"}, method="HEAD")
        with urllib.request.urlopen(req, timeout=8.0) as r:
            final_u = r.geturl()
            # Ensure it redirects to an external file host or .pdf
            if r.status == 200 and final_u != u and ("alfeker.net" not in final_u or final_u.lower().endswith(".pdf")):
                return True, u, final_u
    except Exception:
        pass
    return False, u, ""

def main():
    with open(MATCHING_DB, "r", encoding="utf-8") as f:
        m_db = json.load(f)
    with open(AF_CATALOG_CACHE, "r", encoding="utf-8") as f:
        af_books = json.load(f)

    for b in af_books:
        b["norm_title"] = norm_text(b["title"])
        b["clean_title"] = strip_title_noise(b["title"])
        b["norm_excerpt"] = norm_text(b["excerpt"])

    conn = sqlite3.connect(LIBRARY_DB)
    rem_bids = sorted(set(int(k.split("_")[0]) for k, v in m_db.items() if "ablibrary.net/static/pdf/" in v.get("pdf_url", "")))
    print(f"Checking {len(rem_bids)} remaining books against Alfeker catalog...", flush=True)

    candidate_checks = []
    for bid in rem_bids:
        b_name, author = conn.execute("SELECT book_name, authorName FROM Contents WHERE bookID=? LIMIT 1", (bid,)).fetchone()
        parts = conn.execute("SELECT DISTINCT partID, joze FROM Contents WHERE bookID=? ORDER BY partID", (bid,)).fetchall()
        ct = strip_title_noise(b_name)
        auth_tokens = get_author_tokens(author)

        best_af = None
        best_sc = 0
        for af in af_books:
            af_ct = af["clean_title"]
            af_nt = af["norm_title"]
            if not af_ct:
                continue
            # Avoid non-Arabic translations
            if any(lang in af_nt for lang in ["بنغالي", "bengali", "فارسي", "اردو", "انجليزي", "فرنسي", "تركي"]):
                continue
            # Avoid commentaries/indexes when the book itself isn't one
            if any(w in af_ct for w in ["سند", "اسانيد", "فهارس", "منابع", "مختصر"]) and not any(w in ct for w in ["سند", "اسانيد", "فهارس", "منابع", "مختصر"]):
                continue

            auth_hit = any(w in af["norm_excerpt"] or w in af_nt for w in auth_tokens) if auth_tokens else False
            sc = 0
            if ct == af_ct:
                sc = 100 + (30 if auth_hit else 0)
            elif (ct in af_ct or af_ct in ct) and auth_hit:
                ratio = difflib.SequenceMatcher(None, ct, af_ct).ratio()
                if ratio >= 0.65:
                    sc = int(ratio * 100) + 30
            if sc > best_sc:
                best_sc = sc
                best_af = af

        if best_sc >= 95 and best_af:
            candidate_checks.append((bid, b_name, parts, best_af["id"], best_sc, html.unescape(best_af["title"])))

    conn.close()
    print(f"Found {len(candidate_checks)} high-confidence Alfeker matches. Verifying fk_dl redirects...", flush=True)

    def check_book(item):
        bid, b_name, parts, wp_id, sc, af_title = item
        ok0, u0, final0 = verify_fk_dl_url(wp_id, 0)
        if not ok0:
            return bid, False, wp_id, []
        valid_urls = []
        for idx in range(len(parts)):
            ok_i, u_i, _ = verify_fk_dl_url(wp_id, idx)
            valid_urls.append(u_i if ok_i else u0)
        return bid, True, wp_id, valid_urls

    matched_vols = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
        for (bid, b_name, parts, wp_id, sc, af_title), (_, ok, _, v_urls) in zip(candidate_checks, ex.map(check_book, candidate_checks)):
            if ok:
                for idx, (pid, _) in enumerate(parts):
                    k = f"{bid}_{pid}"
                    if k in m_db and "ablibrary.net/static/pdf/" in m_db[k].get("pdf_url", ""):
                        m_db[k]["pdf_url"] = v_urls[idx]
                        m_db[k]["pdf_source"] = "شبكة الفكر + مكتبة أهل البيت (نسخة مصورة أصلية)"
                        cands = m_db[k].get("candidates", [])
                        cands.insert(0, {"source": "النسخة المصورة الأصلية المباشرة (شبكة الفكر)", "url": v_urls[idx]})
                        m_db[k]["candidates"] = cands
                        matched_vols += 1

    with open(MATCHING_DB, "w", encoding="utf-8") as f:
        json.dump(m_db, f, ensure_ascii=False, indent=2)

    rem_ab_vols = sum(1 for v in m_db.values() if "ablibrary.net/static/pdf/" in v.get("pdf_url", ""))
    rem_ab_pages = sum(int(v.get("ab_pages_count", 0) or 350) for v in m_db.values() if "ablibrary.net/static/pdf/" in v.get("pdf_url", ""))
    print(f"Updated {matched_vols} additional volumes to direct Alfeker PDFs!")
    print(f"Remaining volumes to assemble from Ablibrary original scanned pages: {rem_ab_vols} ({rem_ab_pages:,} pages)")

if __name__ == "__main__":
    main()
