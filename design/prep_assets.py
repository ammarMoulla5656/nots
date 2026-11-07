"""Prepares the images and fonts the design embeds. Run once from the repo root."""
import io, json, sys, warnings
from pathlib import Path
warnings.filterwarnings('ignore')
import pymupdf
from PIL import Image, ImageOps
from fontTools.ttLib import TTCollection, TTFont

OUT = Path('design/assets'); UI = Path('des/assets/images/ui'); COV = Path('des/assets/images/covers')

def webp(im, name, q=70):
    im.save(OUT / f'{name}.webp', 'WEBP', quality=q, method=6)

def fit(im, w):
    return im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)

# Book covers: only the permitted list.
COVERS = [435, 448, 820, 7041, 7045, 7046, 7047, 7001, 7037, 7031, 7010, 7011, 7021, 7020, 7022, 1, 361, 357, 449, 446, 1034]
for c in COVERS:
    webp(fit(Image.open(COV / f'{c}.jpg').convert('RGB'), 260), f'c{c}', 66)

# Category art: the three that show excluded titles are not used.
for n in ['narratives', 'faqah', 'origins', 'doctrine', 'narrators']:
    webp(fit(Image.open(UI / f'{n}.png').convert('RGB'), 720), f'cat-{n}', 60)

# Line art tiles, recoloured through the alpha channel.
def tile(src, name, rgb, w=None):
    im = Image.open(UI / src).convert('RGBA')
    bg = Image.new('RGBA', im.size, (255, 255, 255, 255)); bg.alpha_composite(im)
    a = ImageOps.invert(bg.convert('L'))
    if w: a = fit(a, w)
    t = Image.new('RGBA', a.size, rgb + (0,)); t.putalpha(a)
    t.save(OUT / f'{name}.webp', 'WEBP', quality=60, method=6)
tile('pattern.png', 'tile-script', (255, 255, 255))
tile('pattern.png', 'tile-script-blue', (28, 79, 146))

for n, w in [('alhikmeh-white-logo', 300), ('overlay-logo-fill', 300), ('imamali-sample', 300),
             ('fiqh-dictionary', 520), ('origins-dictionary', 520), ('language-dictionary', 520), ('sounds', 360), ('part-icon', 160)]:
    webp(fit(Image.open(UI / f'{n}.png').convert('RGBA'), w), n, 74)

# The foundation's logo in brand blue, for light surfaces.
im = Image.open(UI / 'alhikmeh-white-logo.png').convert('RGBA')
blue = Image.new('RGBA', im.size, (20, 58, 112, 0)); blue.putalpha(im.getchannel('A'))
webp(blue, 'alhikmeh-blue-logo', 80)

webp(fit(Image.open(UI / 'app-icon.png').convert('RGB'), 132), 'masdar-icon', 80)
webp(fit(Image.open(UI / 'sp-main.png').convert('RGB'), 900), 'splash', 58)
# A piece of the stone tile from the Masdar icon.
st = Image.open(UI / 'launch-logo.png').convert('RGB')
print('launch', st.size)
webp(st.crop((378, 258, 498, 378)).resize((180, 180)), 'stone', 76)

# Real pages of Minhaj al-Salihin vol. 1 with the empty margins removed.
doc = pymupdf.open('نوتس/منهاج الصالحين - الجزء الأول.pdf')
info = {}
for k, idx in enumerate([40, 41]):
    pm = doc[idx].get_pixmap(dpi=190)
    im = Image.frombytes('RGB', (pm.width, pm.height), pm.samples)
    box = ImageOps.invert(im.convert('L')).point(lambda v: 255 if v > 60 else 0).getbbox()
    pad = 44
    box = (max(box[0] - pad, 0), max(box[1] - pad, 0), min(box[2] + pad, im.width), min(box[3] + pad, im.height))
    hi = doc[idx].get_pixmap(dpi=380)
    hi = Image.frombytes('RGB', (hi.width, hi.height), hi.samples).crop(tuple(v * 2 for v in box))
    webp(fit(hi, 1700).convert('L'), f'page{k + 1}', 58)
    im = im.crop(box); im = fit(im, 1000)
    # Text line boxes, used to place the sample ink on the page.
    g = im.convert('L'); w, h = g.size; px = g.load(); rows = []; on = None
    for y in range(h):
        ink = sum(1 for x in range(0, w, 3) if px[x, y] < 120)
        if ink > 3 and on is None: on = y
        if ink <= 3 and on is not None:
            if y - on > 10: rows.append((on, y))
            on = None
    info[f'page{k + 1}'] = {'size': [w, h], 'rows': rows}
    print(k, im.size, len(rows), rows[:6])
json.dump(info, open(OUT / 'pages.json', 'w'))

# Fonts: the app's own Muna and Al Nile keep their tables; only the wrapper changes.
faces = {'muna-400': ('Muna', 0), 'muna-700': ('Muna', 2), 'muna-900': ('Muna', 4), 'nile-400': ('Al-Nile', 0), 'nile-700': ('Al-Nile', 2)}
for name, (fam, i) in faces.items():
    f = TTCollection(f'des/assets/fonts/{fam}.ttc').fonts[i]
    f.flavor = 'woff2'; f.save(OUT / f'{name}.woff2')
tmp = Path(sys.argv[1]) / 'fonts' / 'ArefRuqaa-Regular.ttf'
f = TTFont(tmp); f.flavor = 'woff2'; f.save(OUT / 'ruqaa.woff2')
