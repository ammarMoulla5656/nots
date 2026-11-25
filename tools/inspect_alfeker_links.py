import requests, re, json

headers = {'User-Agent': 'Mozilla/5.0'}
r = requests.get('https://alfeker.net/b/4966/', headers=headers, timeout=10)
# Find where تحميل or أجزاء or pdf is mentioned in 4966
for m in re.finditer(r'(تحميل|الجزء|مجلد|download|data-|btn)', r.text):
    s = max(0, m.start() - 100)
    e = min(len(r.text), m.end() + 200)
    snippet = r.text[s:e]
    if 'href' in snippet or 'data-' in snippet or 'onclick' in snippet:
        print("SNIPPET:", snippet)
        print("="*40)

wp_b = requests.get('https://alfeker.net/wp-json/wp/v2/book', params={'search': 'الكافي'}, headers=headers, timeout=10).json()
print("wp_b count:", len(wp_b))
if wp_b:
    print("wp_b[0] keys:", wp_b[0].keys())
    print("wp_b[0] link/title:", wp_b[0].get('id'), wp_b[0].get('link'), wp_b[0].get('title'))
