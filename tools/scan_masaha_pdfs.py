import urllib.request
import json
import time

headers = {'User-Agent': 'Mozilla/5.0'}

print("Checking books for PDF availability on masaha.org...")
pdf_books = []
for b_id in [1, 2, 3, 4, 5, 10, 15, 20, 30, 50, 75, 100, 150, 200, 300, 400, 500, 600, 700, 800, 900, 1000]:
    url = f"https://www.masaha.org/api/book/{b_id}"
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            b_info = data.get('data', {})
            files = b_info.get('files', {})
            is_pdf = b_info.get('is_pdf_converted')
            has_pdf = ('pdf' in files) or bool(is_pdf)
            print(f"ID {b_id:4d}: {b_info.get('title', '')[:30]:<30} | files: {list(files.keys())} | is_pdf: {is_pdf}")
            if has_pdf:
                pdf_books.append((b_id, b_info.get('title'), files, is_pdf))
    except Exception as e:
        print(f"ID {b_id:4d}: error -> {e}")
    time.sleep(0.1)

print("\nBooks with PDF:", pdf_books)
