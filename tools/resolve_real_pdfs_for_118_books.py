# -*- coding: utf-8 -*-
"""
فحص واستخراج وتأكيد روابط الـ PDF المصورة الأصلية لـ 118 كتاباً (319 مجلداً)
التي كانت تشير إلى grpc.ablibrary.net/static/pdf/ (التي تعطي 404).
يبحث في:
1. الفهرس الكامل لشبكة الفكر (5,728 كتاباً) -> https://alfeker.net/?fk_dl={wp_id}&i={idx}
2. جامع الكتب الإسلامية (ketabonline.com API v2) -> https://s2.ketabonline.com/...pdf
3. المصورات الأصلية لصفحات مكتبة أهل البيت (https://grpc.ablibrary.net/pdf/{ab_id}/pages/1.png)
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
AB_ALL_CACHE = os.path.join(BASE_DIR, "tools", "ablibrary_all_catalog.json")

_DIACRITICS = re.compile(r"[\u064B-\u065F\u0670\u0640\u200c\u200d\u200e\u200f\ufeff]")
_NOT_LETTERS = re.compile(r"[^\w\s]", re.UNICODE)
_LETTERS_MAP = str.maketrans({
    "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
    "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي", "ی": "ي", "ک": "ك"
})

def norm_text(t):
    if not t:
        return ""
    t = html.unescape(str(t))
    t = re.sub(r"<[^>]+>", " ", t)
    t = _DIACRITICS.sub("", t).translate(_LETTERS_MAP)
    t = _NOT_LETTERS.sub(" ", t)
    return " ".join(t.split())

def strip_title_noise(t):
    if not t:
        return ""
    t = html.unescape(str(t))
    t = re.sub(r"<[^>]+>", " ", t)
    t = _DIACRITICS.sub("", t)
    t = re.sub(r"\s*\([^\)]*\)", "", t)
    t = re.sub(r"\s*[-–—]\s*.*$", "", t)
    t = norm_text(t)
    t = re.sub(r"^(كتاب|رساله|منظومه|تفسير)\s+", "", t)
    return t.strip()

def get_author_tokens(author):
    na = norm_text(author or "")
    stop = {
        "الشيخ", "السيد", "قدس", "سره", "رحمه", "الله", "العلامه", "المحقق",
        "الميرزا", "شيخ", "الطائفه", "المحدث", "الامام", "دام", "ظله", "طاب",
        "ثراه", "بن", "ابي", "ابو", "عبد", "محمد", "علي", "حسن", "حسين", "احمد", "الدين"
    }
    tokens = [w for w in na.split() if len(w) >= 4 and w not in stop]
    if not tokens:
        tokens = [w for w in na.split() if len(w) >= 3 and w not in {"قدس", "سره", "رحمه", "الله"}]
    return tokens

def check_ab_scan_png(ab_id):
    if not ab_id:
        return False
    u = f"https://grpc.ablibrary.net/pdf/{ab_id}/pages/1.png"
    try:
        req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"}, method="HEAD")
        with urllib.request.urlopen(req, timeout=6.0) as r:
            return r.status == 200
    except Exception:
        return False

def check_fk_dl(wp_id):
    u = f"https://alfeker.net/?fk_dl={wp_id}&i=0"
    try:
        req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"}, method="HEAD")
        with urllib.request.urlopen(req, timeout=8.0) as r:
            final_u = r.geturl()
            return r.status == 200 and final_u != u, final_u
    except Exception:
        return False, ""

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

    # Identify all books that have any volume pointing to grpc.ablibrary.net/static/pdf
    ab_bids = sorted(set(int(k.split("_")[0]) for k, v in m_db.items() if "ablibrary.net" in v.get("pdf_url", "")))
    print(f"Inspecting {len(ab_bids)} books ({sum(1 for v in m_db.values() if 'ablibrary.net' in v.get('pdf_url',''))} volumes)...", flush=True)

    # Known exact Alfeker WP IDs for major classics
    EXACT_AF_WP_IDS = {
        1: 44,      # الكافي - 8 أجزاء - الشيخ الكليني
        361: 3180,  # من لا يحضره الفقيه - 4 أجزاء - الشيخ الصدوق
        401: 2354,  # الروضة البهية في شرح اللمعة الدمشقية - 10 أجزاء - السيد كلانتر
        449: 1581,  # نهج البلاغة - الصبحي صالح
    }

    results = []
    for bid in ab_bids:
        b_name, author = conn.execute("SELECT book_name, authorName FROM Contents WHERE bookID=? LIMIT 1", (bid,)).fetchone()
        parts = conn.execute("SELECT DISTINCT partID, joze FROM Contents WHERE bookID=? ORDER BY partID", (bid,)).fetchall()
        vols = len(parts)
        first_key = f"{bid}_{parts[0][0]}"
        ab_id = m_db[first_key].get("ab_book_id", "")

        ct = strip_title_noise(b_name)
        nt = norm_text(b_name)
        auth_tokens = get_author_tokens(author)

        # Match in Alfeker catalog
        best_af = None
        best_af_sc = 0
        for af in af_books:
            af_ct = af["clean_title"]
            af_nt = af["norm_title"]
            if not af_ct:
                continue
            auth_hit = any(w in af["norm_excerpt"] or w in af_nt for w in auth_tokens) if auth_tokens else False
            sc = 0
            if ct == af_ct:
                sc = 100 + (30 if auth_hit else 0)
            elif ct in af_ct or af_ct in ct:
                ratio = difflib.SequenceMatcher(None, ct, af_ct).ratio()
                if ratio >= 0.65 or (ratio >= 0.45 and auth_hit):
                    sc = int(ratio * 100) + (30 if auth_hit else 0)
            if sc > best_af_sc:
                best_af_sc = sc
                best_af = af

        has_ab_scan = check_ab_scan_png(ab_id)
        results.append((bid, vols, b_name, author, ab_id, has_ab_scan, best_af_sc, best_af))

    conn.close()

    ab_scan_ok = sum(1 for r in results if r[5])
    af_high_ok = sum(1 for r in results if r[6] >= 85)
    print(f"Summary across {len(results)} books:")
    print(f"  - Have original scanned pages on Ablibrary (/pdf/{{id}}/pages/N.png): {ab_scan_ok}/{len(results)}")
    print(f"  - Have high-confidence match in Alfeker catalog (>=85): {af_high_ok}/{len(results)}")
    for r in results[:35]:
        bid, vols, b_name, author, ab_id, has_scan, af_sc, af = r
        af_str = f"AF:{af['id']} ({af_sc}) '{html.unescape(af['title'])[:35]}'" if af else "No AF"
        print(f"  Book {bid:4d} ({vols:2d}v) | ab:{ab_id:6s} scan:{str(has_scan):5s} | {af_str} | {b_name[:32]}")

if __name__ == "__main__":
    main()
