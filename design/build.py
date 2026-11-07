"""Builds design/nots-design.html: one self-contained file. Run from the repo root."""
import base64
import json
import re
from pathlib import Path

ROOT = Path('design')
SRC, AS = ROOT / 'src', ROOT / 'assets'
ALLOWED = [435, 448, 820, 7041, 7045, 7046, 7047, 7001, 7037, 7031, 7010, 7011, 7021, 7020, 7022, 1, 361, 357, 449, 446, 1034]
IMAGES = ['tile-script', 'stone', 'alhikmeh-white-logo', 'alhikmeh-blue-logo', 'masdar-icon', 'page1', 'page2'] + [f'c{i}' for i in ALLOWED]
CATS = {1: 'تفسير القرآن', 17: 'العقيدة', 18: 'الحديث الشريف', 21: 'الفقه', 22: 'أصول الفقه'}
SHORT = {351: 'السيد السيستاني', 301: 'السيد الحكيم', 9: 'الشيخ الكليني', 88: 'الشيخ الصدوق', 11: 'الشيخ الطوسي',
         365: 'الشريف الرضي', 445: 'السيد اليزدي', 218: 'الشيخ المظفر'}
FEATURES = ['الكتابة بالقلم', 'بحث', 'تعليم الكلمات', 'نسخ النص', 'فهرس', 'نص مصحَّح']
FACES = [('Muna', 400, 'muna-400'), ('Muna', 700, 'muna-700'), ('Muna', 900, 'muna-900'), ('Aref Ruqaa', 400, 'ruqaa')]


def b64(p):
    return base64.b64encode(p.read_bytes()).decode()


assets = {n: f'data:image/webp;base64,{b64(AS / (n + ".webp"))}' for n in IMAGES}
def clean(s):
    return re.sub(r'[‌‎‏]', '', s or '').strip()


books = {b['id']: {'t': clean(b['title']), 'a': clean(b['authorName']), 'as': SHORT.get(b['author'], clean(b['authorName'])),
                   'cat': CATS.get(b['category'], ''), 'count': b.get('count') or 1,
                   'pub': clean((b.get('published') or {}).get('publisher'))}
         for b in json.load(open('des/assets/files/books.json', encoding='utf8')) if b['id'] in ALLOWED}
assert set(books) == set(ALLOWED)
data = {'pages': json.load(open(AS / 'pages.json')), 'books': books, 'features': FEATURES}
fonts = ''.join(
    f"@font-face{{font-family:'{f}';font-weight:{w};font-display:swap;src:url(data:font/woff2;base64,{b64(AS / (n + '.woff2'))}) format('woff2')}}"
    for f, w, n in FACES)

html = f"""<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#1C4F92">
<title>نوتس: قلم المصدر</title>
<style>{fonts}{(SRC / 'app.css').read_text(encoding='utf8')}</style>
</head>
<body>
<script>window.ASSETS={json.dumps(assets)};window.DATA={json.dumps(data, ensure_ascii=False)};</script>
<script>{(SRC / 'app.js').read_text(encoding='utf8')}</script>
</body>
</html>
"""
out = ROOT / 'nots-design.html'
out.write_text(html, encoding='utf8')
print(out, round(out.stat().st_size / 1e6, 2), 'MB')
