import urllib.request
import json

base_url = "https://www.masaha.org/api"

# Let's inspect search
headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Content-Type': 'application/json'
}

# Try GET /api/book/search?query=الكافي or POST
queries = [
    ("POST", f"{base_url}/book/search", json.dumps({"query": "الكافي", "page": 1}).encode('utf-8')),
    ("POST", f"{base_url}/book/search", json.dumps({"word": "الكافي"}).encode('utf-8')),
    ("POST", f"{base_url}/book/search", json.dumps({"title": "الكافي"}).encode('utf-8')),
    ("GET", f"{base_url}/book/search?q=%D8%A7%D9%84%D9%83%D8%A7%D9%81%D9%8A", None),
    ("GET", f"{base_url}/book/search?query=%D8%A7%D9%84%D9%83%D8%A7%D9%81%D9%8A", None),
]

for method, url, data in queries:
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=5) as resp:
            print(f"SUCCESS {method} {url} -> {resp.status}")
            res_data = resp.read()
            print("Response:", res_data[:300])
            break
    except Exception as e:
        print(f"FAIL {method} {url} -> {e}")
