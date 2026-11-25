import requests
import re
import json

headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}

# 1. Check ablibrary.net RSC / HTML content and JS API endpoints
r = requests.get("https://ablibrary.net/search?q=الكافي", headers=headers, timeout=10)
print("ablibrary urls in html:", set(re.findall(r'https?://[^\s"\'<>\\]+', r.text)))
book_links = set(re.findall(r'href=["\']([^"\']*book[^"\']*)["\']', r.text))
print("ablibrary book links:", list(book_links)[:10])

# Search ablibrary JS chunks for api base url or pdf links
for js_path in re.findall(r'src=["\'](/_next/static/chunks/[^"\']+\.js)["\']', r.text):
    js_txt = requests.get("https://ablibrary.net" + js_path, headers=headers, timeout=10).text
    apis = re.findall(r'https?://[^\s"\'`]+', js_txt)
    apis = [a for a in apis if 'w3.org' not in a and 'reactjs' not in a and 'nextjs' not in a]
    if apis:
        print("JS", js_path, "urls:", apis[:10])
    routes = re.findall(r'["\'](/api/[^"\']+)["\']', js_txt)
    if routes:
        print("JS", js_path, "routes:", routes[:10])

# 2. Check alfeker.net search ?s=الكافي
r2 = requests.get("https://alfeker.net/?s=الكافي", headers=headers, timeout=10)
print("\nalfeker ?s=الكافي status:", r2.status_code, "len:", len(r2.text))
af_links = set(re.findall(r'href=["\'](https://alfeker\.net/[^"\']+)["\']', r2.text))
print("alfeker result links:", [l for l in af_links if '/books/' in l or 'library' in l or 'id=' in l][:15])
pdfs = set(re.findall(r'https?://[^\s"\'<>]+\.pdf', r2.text, re.I))
print("alfeker direct pdfs on search page:", list(pdfs)[:10])
