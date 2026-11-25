import requests, json

url = "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/List"
headers = {
    'User-Agent': 'Mozilla/5.0',
    'Content-Type': 'application/json',
    'Connect-Protocol-Version': '1',
}

for q in ["الاستبصار", "الإستبصار", "الخلاف", "قرب الإسناد", "قرب الاسناد", "رجال الطوسي", "المختصر النافع"]:
    payload = {
        "page": 1,
        "perPage": 20,
        "query": q,
        "fuzzy": {"enabled": True}
    }
    r = requests.post(url, json=payload, headers=headers, timeout=10).json()
    books = r.get("books", [])
    with_pdf = [b for b in books if any("PDF" in a.get("context", "") for a in b.get("attachments", []))]
    print(f"Query '{q}': total={len(books)}, with_pdf={len(with_pdf)}")
    for b in books[:3]:
        atts = [a.get("context") for a in b.get("attachments", [])]
        print("  ", b.get("id"), b.get("title"), "vol:", b.get("volumeNumber"), "atts:", atts)
