import requests
import re
import json

headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}

# 1. Inspect ablibrary.net
print("--- 1. Inspecting ablibrary.net ---")
try:
    r = requests.get("https://ablibrary.net/search?q=الكافي", headers=headers, timeout=10)
    print("ablibrary status:", r.status_code, "len:", len(r.text))
    print("ablibrary snippet:", r.text[:500])
    js_files = re.findall(r'src=["\']([^"\']+\.js)["\']', r.text)
    print("ablibrary js files:", js_files)
except Exception as e:
    print("ablibrary err:", e)

# 2. Inspect ketabonline.com API v2 search with title & author
print("\n--- 2. Inspecting ketabonline.com API v2 ---")
KO_HEADERS = {
    'User-Agent': 'Mozilla/5.0',
    'API-KEY': 'chf3T5y9o1YXftncU5pd45QZx9NjkJg',
    'Api-Lang': 'ar',
    'Accept': 'application/json',
}
try:
    r = requests.get("https://backend.ketabonline.com/api/v2/books", params={'q': 'الكافي الكليني'}, headers=KO_HEADERS, timeout=10).json()
    for item in r.get('data', [])[:5]:
        print("KO item:", item.get('id'), item.get('title'), "| parts:", item.get('parts_count'), "| authors:", [a.get('name') for a in item.get('authors', [])])
except Exception as e:
    print("KO err:", e)

# 3. Inspect alfeker.net homepage to see how books/search work
print("\n--- 3. Inspecting alfeker.net ---")
try:
    r = requests.get("https://alfeker.net", headers=headers, timeout=10)
    print("alfeker status:", r.status_code, "len:", len(r.text))
    forms = re.findall(r'<form[^>]*>.*?</form>', r.text, re.S | re.I)
    print("alfeker forms:", forms[:2])
    links = re.findall(r'href=["\']([^"\']+)["\']', r.text)
    print("alfeker sample links:", [l for l in links if 'lib' in l or 'book' in l or 'search' in l][:10])
except Exception as e:
    print("alfeker err:", e)
