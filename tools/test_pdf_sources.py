import urllib.request
import urllib.parse
import json
import re

headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'}

# 1. Test ketabonline API / page
try:
    req = urllib.request.Request('https://ketabonline.com/ar/books/2119', headers=headers)
    html = urllib.request.urlopen(req, timeout=8).read().decode('utf-8', 'ignore')
    pdfs = re.findall(r'https?://[^\s"\'<>]+\.pdf', html, re.I)
    print("ketabonline 2119 pdfs:", pdfs[:5])
except Exception as e:
    print("ketabonline err:", e)

# 2. Test ketabonline search API
for u in [
    'https://ketabonline.com/ar/books?q=' + urllib.parse.quote('الكافي'),
    'https://api.ketabonline.com/v1/books?q=' + urllib.parse.quote('الكافي'),
    'https://backend.ketabonline.com/api/v1/books?q=' + urllib.parse.quote('الكافي'),
]:
    try:
        req = urllib.request.Request(u, headers=headers)
        txt = urllib.request.urlopen(req, timeout=8).read().decode('utf-8', 'ignore')
        print("ketabonline search", u, "len:", len(txt))
        pdfs = re.findall(r'https?://[^\s"\'<>]+\.pdf', txt, re.I)
        if pdfs:
            print("  found pdfs:", pdfs[:3])
    except Exception as e:
        print("ketabonline search err:", u, e)

# 3. Test alfeker search
try:
    req = urllib.request.Request('https://alfeker.net/word.php?find=' + urllib.parse.quote('الكافي'), headers=headers)
    html = urllib.request.urlopen(req, timeout=8).read().decode('utf-8', 'ignore')
    print("alfeker search len:", len(html))
    links = re.findall(r'href=["\']([^"\']*library\.php\?id=\d+[^"\']*)["\']', html)
    print("alfeker links:", links[:5])
except Exception as e:
    print("alfeker err:", e)

# 4. Test shiaonlinelibrary
try:
    req = urllib.request.Request('http://shiaonlinelibrary.com', headers=headers)
    html = urllib.request.urlopen(req, timeout=8).read().decode('utf-8', 'ignore')
    print("shiaonlinelibrary len:", len(html))
except Exception as e:
    print("shiaonlinelibrary err:", e)
