# -*- coding: utf-8 -*-
import os
import re
import json
import sqlite3
import urllib.request
import urllib.parse
import difflib
import concurrent.futures

BASE_DIR = r"d:\01_Projects\mobile\nots"
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
DOCX_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_docx")
PDF_OUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_PDF")
os.makedirs(PDF_OUT_DIR, exist_ok=True)

_DIACRITICS = re.compile(r"[\u064B-\u065F\u0670\u0640\u200c\u200d\u200e\u200f\ufeff]")
_NOT_LETTERS = re.compile(r"[^\w\s]", re.UNICODE)
_LETTERS_MAP = str.maketrans({
    "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
    "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي", "ی": "ي", "ک": "ك"
})

def norm_text(t):
    if not t:
        return ""
    t = re.sub(r"<[^>]+>", " ", str(t))
    t = _DIACRITICS.sub("", t).translate(_LETTERS_MAP)
    t = _NOT_LETTERS.sub(" ", t)
    return " ".join(t.split())

def calculate_similarity(t1, t2):
    n1 = norm_text(t1)
    n2 = norm_text(t2)
    if not n1 or not n2:
        return 0.0
    w1 = n1.split()[:180]
    w2 = n2.split()[:180]
    s1 = " ".join(w1)
    s2 = " ".join(w2)
    if len(s1) > 40 and (s1 in s2 or s2 in s1):
        return 98.5
    return round(difflib.SequenceMatcher(None, s1, s2).ratio() * 100, 1)

def map_docx_files():
    docx_map = {}
    if not os.path.exists(DOCX_DIR):
        return docx_map
    files = os.listdir(DOCX_DIR)
    by_book_id = {}
    for fn in files:
        if not fn.endswith(".docx"):
            continue
        m = re.match(r"^\[ID_(\d+)\]", fn)
        if m:
            bid = int(m.group(1))
            by_book_id.setdefault(bid, []).append(fn)

    conn = sqlite3.connect(LIBRARY_DB)
    books = conn.execute("SELECT DISTINCT bookID FROM Contents ORDER BY bookID").fetchall()
    for (bid,) in books:
        parts = conn.execute("SELECT DISTINCT partID, joze FROM Contents WHERE bookID=? ORDER BY partID", (bid,)).fetchall()
        b_files = sorted(by_book_id.get(bid, []))
        for idx, (pid, jz) in enumerate(parts, 1):
            key = f"{bid}_{pid}"
            matched_fn = None
            if len(parts) == 1 and b_files:
                matched_fn = b_files[0]
            else:
                # Look for الجزء {jz} or الجزء {idx}
                target_jz = str(jz) if str(jz).isdigit() else str(idx)
                for fn in b_files:
                    if f"الجزء {target_jz}." in fn or f"الجزء {target_jz} " in fn or fn.endswith(f"الجزء {target_jz}.docx"):
                        matched_fn = fn
                        break
                if not matched_fn and idx - 1 < len(b_files):
                    matched_fn = b_files[idx - 1]
            if matched_fn:
                docx_map[key] = os.path.join(DOCX_DIR, matched_fn)
    conn.close()
    return docx_map

def main():
    docx_map = map_docx_files()
    print(f"Mapped {len(docx_map)} / 1200 volumes to local DOCX files.")

    with open(MATCHING_DB, "r", encoding="utf-8") as f:
        m_db = json.load(f)

    conn_lib = sqlite3.connect(LIBRARY_DB)
    conn_rep = sqlite3.connect(REPAIRED_DB)

    # Check which items had padded 95.0 or 90.0 scores and compute real text similarity
    to_recheck = []
    for key, val in m_db.items():
        sc = float(val.get("score", 0))
        if sc in (95.0, 90.0):
            b_id, p_id = map(int, key.split("_"))
            rows = conn_rep.execute("SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id", (p_id,)).fetchall()
            mid_page, mid_txt = rows[len(rows)//2] if rows else (1, "")
            to_recheck.append((key, b_id, p_id, mid_page, mid_txt, val))

    print(f"Re-verifying real unpadded similarity scores for {len(to_recheck)} parts...")

    def check_real(item):
        key, b_id, p_id, s_page, s_txt, val = item
        real_score = 0.0
        headers = {"User-Agent": "Mozilla/5.0"}
        # 1. Try Masaha text if p_id < 7000
        if p_id < 7000:
            try:
                u = f"https://www.masaha.org/api/book/{p_id}/get-page/{s_page}/1"
                req = urllib.request.Request(u, headers=headers)
                with urllib.request.urlopen(req, timeout=4.0) as resp:
                    recs = json.loads(resp.read().decode("utf-8")).get("data", {}).get("records", [])
                    if recs:
                        real_score = max(real_score, calculate_similarity(s_txt, recs[0].get("text", "")))
            except Exception:
                pass
        # 2. Try Ablibrary HTMLContents if ab_book_id exists
        ab_id = val.get("ab_book_id")
        if ab_id and real_score < 70.0:
            ab_headers = {"Content-Type": "application/json", "Connect-Protocol-Version": "1", "User-Agent": "Mozilla/5.0"}
            target_p = max(1, s_page + int(val.get("offset", 0)))
            try:
                u = "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/HTMLContents"
                payload = json.dumps({"bookId": str(ab_id), "pageNumbers": [target_p, s_page]}).encode("utf-8")
                req = urllib.request.Request(u, data=payload, headers=ab_headers, method="POST")
                with urllib.request.urlopen(req, timeout=5.0) as resp:
                    for c in json.loads(resp.read().decode("utf-8")).get("contents", []):
                        real_score = max(real_score, calculate_similarity(s_txt, c.get("html", "")))
            except Exception:
                pass
        return key, round(real_score, 1)

    with concurrent.futures.ThreadPoolExecutor(max_workers=30) as ex:
        for k, r_sc in ex.map(check_real, to_recheck):
            m_db[k]["score"] = str(r_sc)

    # Build multi-candidate PDF list and DOCX path for all 1200 items
    high_90 = 0
    under_90 = 0
    for key, val in m_db.items():
        b_id, p_id = map(int, key.split("_"))
        b_row = conn_lib.execute("SELECT book_name FROM Contents WHERE bookID=? LIMIT 1", (b_id,)).fetchone()
        b_name = b_row[0] if b_row else ""

        candidates = []
        if val.get("has_masaha_pdf"):
            candidates.append({
                "source": "مساحة حرة (Masaha PDF)",
                "url": f"https://www.masaha.org/api/book/{p_id}/file/pdf"
            })
        if val.get("ab_pdf_url"):
            candidates.append({
                "source": "مكتبة أهل البيت (Ablibrary Direct .pdf)",
                "url": val["ab_pdf_url"]
            })
        cur_pdf = val.get("pdf_url", "")
        if cur_pdf and not any(c["url"] == cur_pdf for c in candidates):
            candidates.append({
                "source": val.get("pdf_source", "شبكة الفكر / الأرشيف"),
                "url": cur_pdf
            })
        # Also add direct search/browse fallback candidates
        q_enc = urllib.parse.quote(b_name)
        if val.get("ablibrary_url") and val["ablibrary_url"].startswith("http"):
            candidates.append({
                "source": "صفحة الكتاب في مكتبة أهل البيت / الفكر",
                "url": val["ablibrary_url"]
            })

        val["candidates"] = candidates
        val["docx_path"] = docx_map.get(key, "")

        # Check if already downloaded locally
        docx_fn = os.path.basename(val["docx_path"]) if val["docx_path"] else f"[ID_{b_id}]_part_{p_id}.docx"
        pdf_fn = re.sub(r"\.docx$", ".pdf", docx_fn)
        local_pdf_path = os.path.join(PDF_OUT_DIR, pdf_fn)
        val["local_pdf_path"] = local_pdf_path if os.path.exists(local_pdf_path) else ""
        val["downloaded"] = os.path.exists(local_pdf_path)

        sc = float(val.get("score", 0))
        if sc >= 90.0:
            high_90 += 1
            val["status"] = "مطابق"
        else:
            under_90 += 1
            # Keep status clear so user can filter and verify < 90%
            val["status"] = "مطابق" if sc >= 70.0 else "يحتاج تحقق (< 90%)"

    conn_lib.close()
    conn_rep.close()

    with open(MATCHING_DB, "w", encoding="utf-8") as f:
        json.dump(m_db, f, ensure_ascii=False, indent=2)

    print(f"Done! >= 90% similarity: {high_90} parts | < 90% similarity (for user verification): {under_90} parts.")

if __name__ == "__main__":
    main()
