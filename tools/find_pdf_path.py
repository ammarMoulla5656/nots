import urllib.request

urls = [
    "https://www.masaha.org/public/books/pdf/817.pdf",
    "https://www.masaha.org/books/pdf/817.pdf",
    "https://www.masaha.org/storage/books/817.pdf",
    "https://www.masaha.org/storage/pdf/817.pdf",
    "https://www.masaha.org/files/pdf/817.pdf",
    "https://www.masaha.org/api/book/download/700/pdf",
    "https://www.masaha.org/api/book/700/download/pdf",
    "https://www.masaha.org/download/book/700/pdf",
    "https://www.masaha.org/public/files/817.pdf",
    "https://www.masaha.org/public/files/pdf/817.pdf",
]

headers = {'User-Agent': 'Mozilla/5.0'}
for u in urls:
    try:
        req = urllib.request.Request(u, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as resp:
            print("FOUND:", u, "->", resp.status, resp.headers.get('Content-Type'), resp.headers.get('Content-Length'))
            break
    except Exception as e:
        print("404/Fail:", u, "->", e)
