import re

with open('d:/01_Projects/mobile/nots/tools/inspect_masaha.py', 'r', encoding='utf-8') as f:
    pass

req = __import__('urllib.request').request.Request('https://www.masaha.org/main.2bc12237d7e05462.js', headers={'User-Agent': 'Mozilla/5.0'})
js = __import__('urllib.request').request.urlopen(req, timeout=10).read().decode('utf-8', 'ignore')

idx = 0
while True:
    pos = js.find('/book/search', idx)
    if pos == -1:
        break
    print("Found at pos", pos)
    print(js[max(0, pos - 150): min(len(js), pos + 250)])
    print("-" * 50)
    idx = pos + 12
