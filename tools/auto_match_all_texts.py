# -*- coding: utf-8 -*-
"""
أداة الفحص والمطابقة الآلية الشاملة للنصوص بين المصدر ومساحة حرة
Auto Text Matcher & Verifier across all 1200 parts
"""

import sqlite3
import urllib.request
import json
import re
import difflib
import time
import os
import sys
import concurrent.futures

BASE_DIR = r"d:\01_Projects\mobile\nots"
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
EXCEL_PATH = os.path.join(BASE_DIR, "تقرير_مطابقة_كتب_PDF_الشامل.xlsx")

sys.path.append(BASE_DIR)
from tools.generate_matching_excel import generate_excel_catalog

_DIACRITICS = re.compile(r"[\u064B-\u065F\u0670\u0640]")
_NOT_LETTERS = re.compile(r"[^\w\s]", re.UNICODE)
_LETTERS_MAP = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي"})

def normalize_text(text):
    if not text:
        return ""
    clean = re.sub(r"<[^>]+>", " ", text)
    clean = _DIACRITICS.sub("", clean).translate(_LETTERS_MAP)
    clean = _NOT_LETTERS.sub(" ", clean)
    return " ".join(clean.split())

def calculate_similarity(t1, t2):
    n1 = normalize_text(t1)
    n2 = normalize_text(t2)
    if not n1 or not n2:
        return 0.0
    words1 = n1.split()[:180]
    words2 = n2.split()[:180]
    s1 = " ".join(words1)
    s2 = " ".join(words2)
    return round(difflib.SequenceMatcher(None, s1, s2).ratio() * 100, 1)

def get_part_info_and_samples():
    conn_lib = sqlite3.connect(LIBRARY_DB)
    parts = conn_lib.execute("""
        SELECT DISTINCT bookID, partID, book_name, joze 
        FROM Contents 
        ORDER BY bookID, partID
    """).fetchall()
    conn_lib.close()

    conn_rep = sqlite3.connect(REPAIRED_DB)
    items = []
    for b_id, p_id, b_name, joze in parts:
        p_ids = [r[0] for r in conn_rep.execute("SELECT page_id FROM BookPages WHERE part_id=? ORDER BY page_id", (p_id,)).fetchall()]
        if not p_ids:
            continue
        total = len(p_ids)
        s_ids = [p_ids[int(total * 0.25)], p_ids[int(total * 0.50)], p_ids[int(total * 0.75)]]
        samples = []
        for sid in s_ids:
            txt_row = conn_rep.execute("SELECT text FROM BookPages WHERE part_id=? AND page_id=?", (p_id, sid)).fetchone()
            txt = txt_row[0] if txt_row else ""
            samples.append((sid, txt))

        items.append({
            "book_id": b_id,
            "part_id": p_id,
            "book_name": b_name,
            "joze": joze,
            "total_pages": total,
            "samples": samples
        })
    conn_rep.close()
    return items

def check_single_part(item, existing_state):
    b_id = item["book_id"]
    p_id = item["part_id"]
    b_name = item["book_name"]
    key = f"{b_id}_{p_id}"
    
    st = existing_state.get(key, {})
    has_masaha_pdf = st.get("has_masaha_pdf", False)
    masaha_url = st.get("masaha_url", f"https://www.masaha.org/book/{p_id}")
    ablibrary_url = st.get("ablibrary_url", f"https://ablibrary.net/search?q={urllib.parse.quote(b_name)}")
    pdf_url = st.get("pdf_url", f"https://www.masaha.org/api/book/{p_id}/file/pdf" if has_masaha_pdf else "")

    headers = {'User-Agent': 'Mozilla/5.0'}
    
    # Check 50% sample first
    p50_no, p50_txt = item["samples"][1]
    url50 = f"https://www.masaha.org/api/book/{p_id}/get-page/{p50_no}/1"
    
    scores = []
    matched_offset = 0
    try:
        req = urllib.request.Request(url50, headers=headers)
        with urllib.request.urlopen(req, timeout=3.5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            recs = data.get('data', {}).get('records', [])
            if recs:
                txt50 = recs[0].get('text', '')
                sc = calculate_similarity(p50_txt, txt50)
                scores.append(sc)
    except Exception:
        pass

    # If score50 >= 70%, check 75% sample to confirm
    if scores and scores[0] >= 70:
        p75_no, p75_txt = item["samples"][2]
        url75 = f"https://www.masaha.org/api/book/{p_id}/get-page/{p75_no}/1"
        try:
            req = urllib.request.Request(url75, headers=headers)
            with urllib.request.urlopen(req, timeout=3.5) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                recs = data.get('data', {}).get('records', [])
                if recs:
                    txt75 = recs[0].get('text', '')
                    sc75 = calculate_similarity(p75_txt, txt75)
                    scores.append(sc75)
        except Exception:
            pass
    elif not scores or scores[0] < 50:
        # Check 25% sample
        p25_no, p25_txt = item["samples"][0]
        url25 = f"https://www.masaha.org/api/book/{p_id}/get-page/{p25_no}/1"
        try:
            req = urllib.request.Request(url25, headers=headers)
            with urllib.request.urlopen(req, timeout=3.5) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                recs = data.get('data', {}).get('records', [])
                if recs:
                    txt25 = recs[0].get('text', '')
                    sc25 = calculate_similarity(p25_txt, txt25)
                    scores.append(sc25)
        except Exception:
            pass

    max_score = max(scores) if scores else 0.0
    avg_score = round(sum(scores) / len(scores), 1) if scores else 0.0

    # Decision: is it matching?
    if max_score >= 65.0:
        is_match = True
        status_label = "مطابق"
        note = f"تطابق نصي معتمد مع مساحة حرة بنسبة {max_score}%"
        if has_masaha_pdf:
            note += " (متوفر PDF مباشر بمساحة حرة)"
        else:
            note += " (النص مطابق، يحمل PDF من أهل البيت)"
    else:
        is_match = False
        status_label = "غير متوفر بمساحة حرة - يفحص بأهل البيت"
        note = f"نسبة التطابق منخفضة ({avg_score}%) - متاح في مكتبة أهل البيت"

    return {
        "key": key,
        "book_id": b_id,
        "part_id": p_id,
        "book_name": b_name,
        "status": status_label,
        "is_match": is_match,
        "offset": matched_offset,
        "pdf_url": pdf_url,
        "masaha_url": masaha_url,
        "has_masaha_pdf": has_masaha_pdf,
        "is_pdf_converted": st.get("is_pdf_converted", False),
        "ablibrary_url": ablibrary_url,
        "score": str(max_score) if max_score > 0 else "--",
        "notes": note
    }

def main():
    print("=" * 70, flush=True)
    print("🚀 بدء الفحص والمطابقة الآلية للنصوص عبر كافة أجزاء المكتبة (1200 مجلد)...", flush=True)
    print("=" * 70, flush=True)

    # 1. Load existing state
    existing_state = {}
    if os.path.exists(MATCHING_DB):
        try:
            with open(MATCHING_DB, "r", encoding="utf-8") as f:
                existing_state = json.load(f)
        except Exception:
            existing_state = {}

    # 2. Get samples
    t0 = time.time()
    items = get_part_info_and_samples()
    total_parts = len(items)
    print(f"تم استخراج العينات لـ {total_parts} مجلداً في {time.time()-t0:.1f} ثانية.", flush=True)
    print("جاري مقارنة النصوص عبر الإنترنت بواسطة 35 خيطاً متوازياً...", flush=True)

    start_time = time.time()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=35) as executor:
        futures = {executor.submit(check_single_part, it, existing_state): it for it in items}
        done = 0
        for fut in concurrent.futures.as_completed(futures):
            res = fut.result()
            results.append(res)
            done += 1
            if done % 150 == 0 or done == total_parts:
                matched_so_far = sum(1 for r in results if r["is_match"])
                print(f"[{done:4d}/{total_parts}] منجز | المتطابق نصياً حتى الآن (صح ✔️): {matched_so_far}", flush=True)

    elapsed = time.time() - start_time
    print(f"\nاكتمل الفحص الآلي في {elapsed:.1f} ثانية!", flush=True)

    # 3. Calculate statistics
    total_matched = sum(1 for r in results if r["is_match"])
    has_pdf_count = sum(1 for r in results if r["has_masaha_pdf"])
    matched_with_pdf = sum(1 for r in results if r["is_match"] and r["has_masaha_pdf"])
    matched_need_pdf = sum(1 for r in results if r["is_match"] and not r["has_masaha_pdf"])
    unmatched_count = total_parts - total_matched

    print("=" * 70, flush=True)
    print(f"📊 النتائج الإحصائية الدقيقة للمطابقة النصية:", flush=True)
    print(f"   ✔️ إجمالي المجلدات المتطابقة نصياً (صح): {total_matched} من {total_parts} ({total_matched/total_parts*100:.1f}%)", flush=True)
    print(f"   📥 متطابقة نصياً ومتوفر لها PDF مباشر فوراً بمساحة حرة: {matched_with_pdf} مجلد", flush=True)
    print(f"   🏛️ متطابقة نصياً ولكن تحتاج تحميل PDF من مكتبة أهل البيت: {matched_need_pdf} مجلد", flush=True)
    print(f"   ⚠️ غير متطابقة نصياً بمساحة حرة (تفحص بمكتبة أهل البيت): {unmatched_count} مجلد", flush=True)
    print("=" * 70, flush=True)

    # 4. Save to matching database
    updated_state = {}
    for r in results:
        updated_state[r["key"]] = {
            "status": r["status"],
            "offset": r["offset"],
            "pdf_url": r["pdf_url"],
            "masaha_url": r["masaha_url"],
            "has_masaha_pdf": r["has_masaha_pdf"],
            "is_pdf_converted": r["is_pdf_converted"],
            "ablibrary_url": r["ablibrary_url"],
            "score": r["score"],
            "notes": r["notes"]
        }

    with open(MATCHING_DB, "w", encoding="utf-8") as f:
        json.dump(updated_state, f, ensure_ascii=False, indent=2)

    # 5. Update Excel
    print("جاري تحديث تقرير الإكسل الشامل...", flush=True)
    generate_excel_catalog(updated_state)
    print(f"✅ تم حفظ وتحديث ملف الإكسل: {EXCEL_PATH}", flush=True)

if __name__ == '__main__':
    main()
