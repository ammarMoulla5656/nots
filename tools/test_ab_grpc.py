import requests, json

url = "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/List"
headers = {
    'User-Agent': 'Mozilla/5.0',
    'Content-Type': 'application/json',
    'Connect-Protocol-Version': '1',
}
for payload in [
    {"page": 1, "perPage": 5, "attachments": [{"context": "BOOK_ATTACHMENT_CONTEXT_PDF"}]},
    {"page": 1, "perPage": 5},
]:
    r = requests.post(url, json=payload, headers=headers, timeout=10)
    print(payload, "->", r.status_code, r.json().get("pagination"))
