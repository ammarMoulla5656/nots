import urllib.request
import urllib.parse
import json
import ssl

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

def fetch(url):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            return resp.status, resp.read().decode('utf-8', errors='ignore')
    except Exception as e:
        return None, str(e)

# Test home page of masaha.org
status, content = fetch("https://masaha.org")
print("masaha.org status:", status, "length:", len(content) if content else 0)
if content:
    print("Sample content:", content[:500])

# Test search for الكافي
query = urllib.parse.quote("الكافي")
status, search_res = fetch(f"https://masaha.org/search?q={query}")
print("\nSearch status:", status, "length:", len(search_res) if search_res else 0)
if search_res:
    print("Search sample:", search_res[:500])
