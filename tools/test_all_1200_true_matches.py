# -*- coding: utf-8 -*-
import os
import re
import json
import sqlite3
import urllib.request
import urllib.parse
import difflib
import concurrent.futures
import time

BASE_DIR = r"d:\01_Projects\mobile\nots"
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
AB_ALL_CACHE = os.path.join(BASE_DIR, "tools", "ablibrary_all_catalog.json")

_DIACRITICS = re.compile(r"[\u064B-\u065F\u0670\u0640\u200c-\u200f\ufeff]")
_NOT_LETTERS = re.compile(r"[^\w\s]", re.UNICODE)
_mp = {
    "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
    "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي", "ی": "ي", "ک": "ك"
}
for _i, _c in enumerate("٠١٢٣٤٥٦٧٨٩"):
    _mp[_c] = str(_i)
for _i, _c in enumerate("۰۱۲۳۴۵۶۷۸۹"):
    _mp[_c] = str(_i)
_LETTERS_MAP = str.maketrans(_mp)

def clean_body_text(t, strip_footnotes=True):
    if not t:
        return ""
    s = str(t)
    if "\x00" in s:
        s = s.split("\x00")[0]
    if strip_footnotes:
        s = re.sub(r'<div[^>]*footnote[^>]*>.*?</div>', ' ', s, flags=re.DOTALL | re.IGNORECASE)
        s = re.sub(r'<p[^>]*class=["\']?fnote["\']?[^>]*>.*?</p>', ' ', s, flags=re.DOTALL | re.IGNORECASE)
        s = re.sub(r'<fnote>.*?</fnote>', ' ', s, flags=re.DOTALL | re.IGNORECASE)
        if "____________" in s:
            s = s.split("____________")[0]
        s = re.split(r"(?:_{4,}|\u0640{4,}|─{4,})", s)[0]
    s = re.sub(r"<[^>]+>", " ", s)
    s = re.sub(r"\[[^\]]*\]", " ", s)
    s = _DIACRITICS.sub("", s).translate(_LETTERS_MAP)
    s = _NOT_LETTERS.sub(" ", s)
    s = re.sub(r"\b\d+\b", " ", s)
    s = " ".join(s.split())
    s = re.sub(r"\bو\s+", "و", s)
    return " ".join(s.split())

def compute_page_similarity(db_text, remote_text):
    for strip_fn in (True, False):
        c1 = clean_body_text(db_text, strip_footnotes=strip_fn)
        c2 = clean_body_text(remote_text, strip_footnotes=strip_fn)
        if not c1 or not c2:
            continue
        w1 = c1.split()[:220]
        w2 = c2.split()[:220]
        s1 = " ".join(w1)
        s2 = " ".join(w2)
        if len(s1) >= 30 and (s1 in s2 or s2 in s1):
            return 99.5
        seq_ratio = difflib.SequenceMatcher(None, s1, s2, autojunk=False).ratio() * 100.0
        # Also compute bigram & word containment when one side has extra chains/commentary
        shorter, longer = (w1, w2) if len(w1) <= len(w2) else (w2, w1)
        if len(shorter) >= 12:
            bg_short = {(shorter[i], shorter[i+1]) for i in range(len(shorter)-1)}
            bg_long = {(longer[i], longer[i+1]) for i in range(len(longer)-1)}
            bg_hit = len(bg_short & bg_long) / max(1, len(bg_short)) * 100.0
            w_set = set(longer)
            w_hit = sum(1 for w in shorter if w in w_set) / len(shorter) * 100.0
            combined = max(seq_ratio, (bg_hit * 0.65 + w_hit * 0.35) if bg_hit >= 55 else seq_ratio)
        else:
            combined = seq_ratio
        if strip_fn and combined >= 85.0:
            return round(min(100.0, combined), 1)
        best = round(min(100.0, combined), 1)
    return best if 'best' in locals() else 0.0

def split_ab_html_pages(html_data):
    if not html_data:
        return []
    parts = re.split(r'<div\s+class=["\']page["\']>', html_data)
    return [p for p in parts[1:] if p.strip()] or [html_data]

def main():
    with open(MATCHING_DB, "r", encoding="utf-8") as f:
        m_db = json.load(f)
    with open(AB_ALL_CACHE, "r", encoding="utf-8") as f:
        ab_all = json.load(f)
    ab_by_id = {x["id"]: x for x in ab_all}

    conn_rep = sqlite3.connect(REPAIRED_DB)
    conn_lib = sqlite3.connect(LIBRARY_DB)

    # Gather sample pages for all 1200 parts
    tasks = []
    for key, val in m_db.items():
        b_id, p_id = map(int, key.split("_"))
        rows = conn_rep.execute("SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id", (p_id,)).fetchall()
        # Pick up to 2 rich pages (around 40% and 60%)
        rich_rows = [(p, t) for p, t in rows if len(clean_body_text(t)) >= 120]
        if not rich_rows:
            rich_rows = rows
        samples = []
        if rich_rows:
            samples.append(rich_rows[len(rich_rows) // 2])
            if len(rich_rows) >= 4:
                samples.append(rich_rows[len(rich_rows) // 3])
        first_db_page = rows[0][0] if rows else 1
        tasks.append((key, b_id, p_id, first_db_page, samples, val))

    conn_rep.close()
    conn_lib.close()

    print(f"Testing {len(tasks)} volumes with fixed Ablibrary HTMLContents ('data') & normalized similarity...", flush=True)

    def check_one(item):
        key, b_id, p_id, first_db_page, samples, val = item
        if not samples:
            return key, 0.0, val.get("pdf_source", ""), val.get("offset", 0)

        headers = {"User-Agent": "Mozilla/5.0"}
        ab_headers = {"Content-Type": "application/json", "Connect-Protocol-Version": "1", "User-Agent": "Mozilla/5.0"}

        ms_best_score = 0.0
        ms_offset = int(val.get("offset", 0))
        # 1. Check Masaha if p_id < 7000
        if p_id < 7000:
            for s_page, s_txt in samples[:2]:
                try:
                    u = f"https://www.masaha.org/api/book/{p_id}/get-page/{s_page}/1"
                    req = urllib.request.Request(u, headers=headers)
                    with urllib.request.urlopen(req, timeout=4.5) as resp:
                        recs = json.loads(resp.read().decode("utf-8")).get("data", {}).get("records", [])
                        for r in recs:
                            sc = compute_page_similarity(s_txt, r.get("text", ""))
                            if sc > ms_best_score:
                                ms_best_score = sc
                except Exception:
                    pass
                if ms_best_score >= 92.0:
                    break

        # 2. Check Ablibrary if ab_book_id is present and (ms_best_score < 92 or no masaha pdf)
        ab_best_score = 0.0
        ab_offset = int(val.get("offset", 0))
        ab_id = val.get("ab_book_id")
        if ab_id and (ms_best_score < 92.0 or not val.get("has_masaha_pdf")):
            s_page, s_txt = samples[0]
            try:
                # Get PagesMeta matching labels
                meta_u = "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/PagesMeta"
                req_m = urllib.request.Request(meta_u, data=json.dumps({"bookId": str(ab_id)}).encode(), headers=ab_headers, method="POST")
                cand_nums = []
                with urllib.request.urlopen(req_m, timeout=5.0) as resp_m:
                    pages = json.loads(resp_m.read().decode("utf-8")).get("pages", [])
                    for p in pages:
                        if str(p.get("label", "")).strip() == str(s_page):
                            cand_nums.append(int(p.get("number", 0)))
                if not cand_nums:
                    cand_nums = [max(1, s_page + ab_offset), s_page]
                else:
                    # Also include nearby page +/- 1 in case of page boundary split
                    extra = []
                    for n in cand_nums:
                        extra.extend([max(1, n - 1), n, n + 1])
                    cand_nums = sorted(set(extra))[:8]

                html_u = "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/HTMLContents"
                req_h = urllib.request.Request(html_u, data=json.dumps({"bookId": str(ab_id), "pageNumbers": cand_nums}).encode(), headers=ab_headers, method="POST")
                with urllib.request.urlopen(req_h, timeout=6.0) as resp_h:
                    html_data = json.loads(resp_h.read().decode("utf-8")).get("data", "")
                    for p_chunk in split_ab_html_pages(html_data):
                        sc = compute_page_similarity(s_txt, p_chunk)
                        if sc > ab_best_score:
                            ab_best_score = sc
                    # Also check combined chunk in case sentence spans 2 pages
                    sc_all = compute_page_similarity(s_txt, html_data)
                    if sc_all > ab_best_score:
                        ab_best_score = sc_all
            except Exception:
                pass

        return key, ms_best_score, ab_best_score, ab_offset

    t0 = time.time()
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=35) as ex:
        futs = [ex.submit(check_one, t) for t in tasks]
        done = 0
        for fut in concurrent.futures.as_completed(futs):
            k, ms_sc, ab_sc, ab_off = fut.result()
            results[k] = (ms_sc, ab_sc, ab_off)
            done += 1
            if done % 300 == 0 or done == len(tasks):
                print(f"  [{done:4d}/{len(tasks)}] checked ({time.time()-t0:.1f}s)", flush=True)

    ge_90 = sum(1 for k, (ms, ab, _) in results.items() if max(ms, ab) >= 90.0)
    ge_80 = sum(1 for k, (ms, ab, _) in results.items() if 80.0 <= max(ms, ab) < 90.0)
    lt_80 = sum(1 for k, (ms, ab, _) in results.items() if max(ms, ab) < 80.0)
    print(f"SUMMARY: >=90%: {ge_90} | 80-89.9%: {ge_80} | <80%: {lt_80}", flush=True)

    with open(os.path.join(BASE_DIR, "tools", "diag_scores.json"), "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

if __name__ == "__main__":
    main()
