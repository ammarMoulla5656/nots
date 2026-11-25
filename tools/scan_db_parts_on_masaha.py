import sqlite3
import urllib.request
import json
import concurrent.futures

conn = sqlite3.connect('library.db')
parts = conn.execute("SELECT DISTINCT partID, bookID, book_name, joze FROM Contents ORDER BY partID").fetchall()
conn.close()

print(f"Total parts in library.db: {len(parts)}")

def check_masaha(part):
    p_id, b_id, b_name, joze = part
    url = f"https://www.masaha.org/api/book/{p_id}"
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            b_info = data.get('data', {})
            files = b_info.get('files', {})
            is_pdf = b_info.get('is_pdf_converted', False)
            has_pdf = ('pdf' in files) or bool(is_pdf)
            return {
                "part_id": p_id,
                "book_id": b_id,
                "book_name": b_name,
                "joze": joze,
                "masaha_title": b_info.get('title'),
                "has_pdf": has_pdf,
                "is_pdf_converted": is_pdf,
                "pdf_file": files.get('pdf'),
                "files": list(files.keys())
            }
    except Exception as e:
        return None

# Check the first 50 parts in parallel
print("Scanning first 50 parts...")
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
    results = list(executor.map(check_masaha, parts[:50]))

found_masaha = [r for r in results if r]
print(f"Found on Masaha: {len(found_masaha)}/{len(results)}")
has_pdf_list = [r for r in found_masaha if r['has_pdf']]
print(f"Has PDF: {len(has_pdf_list)}")
for r in has_pdf_list:
    print(r)
