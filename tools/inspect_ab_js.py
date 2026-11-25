import requests, re, base64

headers = {'User-Agent': 'Mozilla/5.0'}
txt = requests.get("https://ablibrary.net/_next/static/chunks/03j_bfb4kuet~.js", headers=headers, timeout=10).text
for b64 in re.findall(r'fileDesc\)\(["\']([A-Za-z0-9+/=_~-]+)["\']', txt):
    b64_std = b64 + '=' * (-len(b64) % 4)
    raw = base64.b64decode(b64_std)
    printable = ''.join(chr(c) if 32 <= c < 127 else ' ' for c in raw)
    if 'book_service' in printable:
        print(re.sub(r'\s+', ' ', printable))
