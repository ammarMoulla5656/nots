import sqlite3
import urllib.request
import json
import re
import difflib

REPAIRED_DB = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"
LIBRARY_DB = r"d:\01_Projects\mobile\nots\library.db"

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
    words1 = n1.split()[:200]
    words2 = n2.split()[:200]
    s1 = " ".join(words1)
    s2 = " ".join(words2)
    return round(difflib.SequenceMatcher(None, s1, s2).ratio() * 100, 1)

def test_part_similarity(p_id):
    conn = sqlite3.connect(REPAIRED_DB)
    pages = conn.execute("SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id", (p_id,)).fetchall()
    conn.close()
    if not pages:
        return None
    
    # Check 3 points: 25%, 50%, 75%
    total = len(pages)
    chk_indices = [int(total * 0.25), int(total * 0.50), int(total * 0.75)]
    scores = []
    
    headers = {'User-Agent': 'Mozilla/5.0'}
    for idx in chk_indices:
        p_no, src_txt = pages[idx]
        url = f"https://www.masaha.org/api/book/{p_id}/get-page/{p_no}/1"
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=3) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                recs = data.get('data', {}).get('records', [])
                if recs:
                    masaha_txt = recs[0].get('text', '')
                    sc = calculate_similarity(src_txt, masaha_txt)
                    scores.append(sc)
        except Exception as e:
            pass
            
    avg_score = round(sum(scores) / len(scores), 1) if scores else 0.0
    return avg_score, scores

# Test sample parts: 1 (Al-Kafi 1), 29 (Al-Istibsar 1), 150 (Al-Tibyan 1), 2074 (Bihar 1), 2534 (Al-Mizan 1)
test_parts = [1, 29, 150, 2074, 2534]
print("Testing sample parts text matching...")
for p in test_parts:
    res = test_part_similarity(p)
    print(f"Part {p}: Avg Score = {res[0]}%, Scores = {res[1]}")
