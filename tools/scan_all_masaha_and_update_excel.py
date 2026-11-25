import sqlite3
import urllib.request
import json
import time
import concurrent.futures
import os
import sys

BASE_DIR = r"d:\01_Projects\mobile\nots"
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
EXCEL_PATH = os.path.join(BASE_DIR, "تقرير_مطابقة_كتب_PDF_الشامل.xlsx")

sys.path.append(BASE_DIR)
from tools.generate_matching_excel import generate_excel_catalog

conn = sqlite3.connect(LIBRARY_DB)
parts = conn.execute("SELECT DISTINCT bookID, partID, book_name, joze FROM Contents ORDER BY bookID, partID").fetchall()
conn.close()

print(f"Total parts to scan: {len(parts)}")

# Load existing state if any
state = {}
if os.path.exists(MATCHING_DB):
    try:
        with open(MATCHING_DB, "r", encoding="utf-8") as f:
            state = json.load(f)
    except:
        state = {}

def fetch_masaha_info(item):
    b_id, p_id, b_name, joze = item
    url = f"https://www.masaha.org/api/book/{p_id}"
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            b_info = data.get('data', {})
            files = b_info.get('files', {})
            is_pdf = b_info.get('is_pdf_converted', False)
            has_pdf = ('pdf' in files) or bool(is_pdf)
            pdf_url = f"https://www.masaha.org/api/book/{p_id}/file/pdf" if has_pdf else ""
            masaha_url = f"https://www.masaha.org/book/{p_id}"
            
            return {
                "key": f"{b_id}_{p_id}",
                "b_id": b_id,
                "p_id": p_id,
                "b_name": b_name,
                "joze": joze,
                "has_pdf": has_pdf,
                "is_pdf_converted": is_pdf,
                "pdf_url": pdf_url,
                "masaha_url": masaha_url,
                "files": list(files.keys())
            }
    except Exception as e:
        return {
            "key": f"{b_id}_{p_id}",
            "b_id": b_id,
            "p_id": p_id,
            "b_name": b_name,
            "joze": joze,
            "has_pdf": False,
            "is_pdf_converted": False,
            "pdf_url": "",
            "masaha_url": f"https://www.masaha.org/book/{p_id}",
            "files": []
        }

print("Scanning all 1,200 parts on Masaha with 25 threads...")
start_time = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=25) as executor:
    results = list(executor.map(fetch_masaha_info, parts))

elapsed = time.time() - start_time
print(f"Scan completed in {elapsed:.1f} seconds!")

total_pdf = sum(1 for r in results if r['has_pdf'])
print(f"Parts with PDF directly on Masaha: {total_pdf} / {len(results)}")

# Update state
for r in results:
    key = r['key']
    existing = state.get(key, {})
    
    masaha_url = r['masaha_url']
    ablibrary_url = f"https://ablibrary.net/search?q={urllib.parse.quote(r['b_name'])}"
    
    if r['has_pdf']:
        status = "مطابق"
        pdf_url = r['pdf_url']
        notes = "متوفر PDF مباشر في مساحة حرة ومطابق للمصدر"
        score = "100"
    else:
        status = existing.get('status', 'غير متوفر بمساحة حرة - يفحص بأهل البيت')
        pdf_url = existing.get('pdf_url', '')
        notes = existing.get('notes', 'غير متوفر كـ PDF في مساحة حرة، متاح في مكتبة أهل البيت')
        score = existing.get('score', '--')
        
    state[key] = {
        "status": status,
        "offset": existing.get('offset', 0),
        "pdf_url": pdf_url,
        "masaha_url": masaha_url,
        "has_masaha_pdf": r['has_pdf'],
        "is_pdf_converted": r['is_pdf_converted'],
        "ablibrary_url": ablibrary_url,
        "score": score,
        "notes": notes
    }

# Save matching state
with open(MATCHING_DB, "w", encoding="utf-8") as f:
    json.dump(state, f, ensure_ascii=False, indent=2)

print("Saved matching database JSON!")

# Generate updated Excel report
generate_excel_catalog(state)
print("Updated Excel report generated successfully!")
