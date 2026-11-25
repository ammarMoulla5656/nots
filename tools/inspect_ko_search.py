import requests, re

headers = {'User-Agent': 'Mozilla/5.0'}
for f in ['177ada0.js', '1d9478e.js', 'dacd808.js', 'c8b0283.js', 'b2142c8.js', 'c2c0ce1.js']:
    txt = requests.get('https://ketabonline.com/_nuxt/' + f, headers=headers, timeout=10).text
    for m in re.finditer(r'books', txt):
        s = max(0, m.start() - 80)
        e = min(len(txt), m.end() + 120)
        snip = txt[s:e]
        if 'api' in snip or 'get(' in snip or 'params' in snip or 'query' in snip or 'search' in snip:
            print(f, "->", snip)
