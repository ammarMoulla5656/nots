req = __import__('urllib.request').request.Request('https://www.masaha.org/main.2bc12237d7e05462.js', headers={'User-Agent': 'Mozilla/5.0'})
js = __import__('urllib.request').request.urlopen(req, timeout=10).read().decode('utf-8', 'ignore')

pos = 0
while True:
    pos = js.find('files.pdf', pos)
    if pos == -1:
        break
    print("Found 'files.pdf' at", pos)
    print(js[max(0, pos-100):min(len(js), pos+200)])
    print('='*50)
    pos += 9
