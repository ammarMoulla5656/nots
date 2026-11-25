import requests, json

KO_HEADERS = {
    'User-Agent': 'Mozilla/5.0',
    'API-KEY': 'chf3T5y9o1YXftncU5pd45QZx9NjkJg',
    'Api-Lang': 'ar',
    'Accept': 'application/json',
}

test_books = [
    "قرب الإسناد",
    "رجال الطوسي",
    "المختصر النافع",
    "الخلاف الطوسي",
    "التبيان في تفسير القرآن",
    "شرح البداية في علم الدراية",
    "المسائل المنتخبة السيستاني",
]

print("=== 1. Testing KetabOnline API v2 ===")
for q in test_books:
    r = requests.get("https://backend.ketabonline.com/api/v2/books", params={"q": q, "scope": "titles"}, headers=KO_HEADERS, timeout=10).json()
    data = r.get("data", [])
    print(f"KO '{q}': found {len(data)}")
    for b in data[:3]:
        b_id = b.get("id")
        # fetch book details to get parts pdf_url
        det = requests.get(f"https://backend.ketabonline.com/api/v2/books/{b_id}", headers=KO_HEADERS, timeout=10).json().get("data", {})
        parts = det.get("parts", [])
        pdfs = [p.get("pdf_url") for p in parts if p.get("pdf_url")]
        print(f"   KO ID {b_id}: {b.get('title')} | Authors: {[a.get('name') for a in b.get('authors', [])]} | PDFs: {len(pdfs)} -> {pdfs[:2]}")

print("\n=== 2. Testing Masaha Search for Alternate IDs with PDF ===")
for q in test_books:
    r = requests.post("https://www.masaha.org/api/book/search", json={"q": q.split()[0] + " " + (q.split()[1] if len(q.split())>1 else "")}, headers={'User-Agent': 'Mozilla/5.0'}, timeout=10).json()
    recs = r.get("data", {}).get("records", []) if isinstance(r.get("data"), dict) else []
    print(f"Masaha '{q}': found {len(recs)}")
    for rec in recs[:3]:
        det = requests.get(f"https://www.masaha.org/api/book/{rec['id']}", headers={'User-Agent': 'Mozilla/5.0'}, timeout=10).json().get("data", {})
        files = det.get("files", {})
        print(f"   Masaha ID {rec['id']}: {det.get('title')} | files: {files}")
