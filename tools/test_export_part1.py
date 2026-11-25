import sqlite3
import time
import re
import os
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import parse_xml
from docx.oxml.ns import nsdecls

t0 = time.time()
db_path = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"
lib_path = r"d:\01_Projects\mobile\nots\library.db"

conn = sqlite3.connect(db_path)
conn_lib = sqlite3.connect(lib_path)

# Fetch pages for part_id = 1 (الكافي جزء 1)
pages = conn.execute("SELECT page_id, text FROM BookPages WHERE part_id=1 ORDER BY page_id").fetchall()
print(f"Fetched {len(pages)} pages in {time.time() - t0:.2f}s")

# Fetch TOC for part_id = 1
toc = conn_lib.execute("SELECT pageID, title, level FROM Contents WHERE partID=1 ORDER BY pageID, level").fetchall()
print(f"Fetched {len(toc)} TOC entries in {time.time() - t0:.2f}s")

doc = Document()
for s in doc.sections:
    s.page_width = Inches(8.27)
    s.page_height = Inches(11.69)
    s.top_margin = Inches(0.8)
    s.bottom_margin = Inches(0.8)
    s.left_margin = Inches(0.8)
    s.right_margin = Inches(0.8)

def set_p_rtl(p, align=WD_ALIGN_PARAGRAPH.RIGHT):
    pPr = p._element.get_or_add_pPr()
    pPr.append(parse_xml(r'<w:bidi %s/>' % nsdecls('w')))
    p.alignment = align

def set_r_font(run, font_name="Traditional Arabic", size_pt=14, bold=False, color=None):
    rPr = run._element.get_or_add_rPr()
    rPr.append(parse_xml(r'<w:rtl %s/>' % nsdecls('w')))
    run.font.name = font_name
    rFonts = parse_xml(r'<w:rFonts %s w:ascii="%s" w:hAnsi="%s" w:cs="%s"/>' % (nsdecls('w'), font_name, font_name, font_name))
    rPr.append(rFonts)
    if size_pt:
        run.font.size = Pt(size_pt)
    if bold:
        run.bold = True
    if color:
        run.font.color.rgb = color

COLOR_BLUE = RGBColor(0, 102, 204)
COLOR_RED = RGBColor(180, 20, 20)
COLOR_GREEN = RGBColor(0, 128, 0)
COLOR_PURPLE = RGBColor(128, 0, 128)
COLOR_DARK_GRAY = RGBColor(80, 80, 80)
COLOR_PAGE_BADGE = RGBColor(140, 80, 20)

XML_CONTROL_CHARS = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')
def clean_xml(s):
    return XML_CONTROL_CHARS.sub('', s) if s else ''

token_pattern = re.compile(r'(<[^>]+>|[^<]+)')

def render_html_tokens(p, text):
    text = clean_xml(text)
    tokens = token_pattern.findall(text)
    current_color = None
    is_bold = False
    is_fn = False
    is_fm = False
    
    for tok in tokens:
        if not tok:
            continue
        low = tok.lower()
        if low == '<blue>':
            current_color = COLOR_BLUE
        elif low == '</blue>':
            current_color = None
        elif low == '<red>':
            current_color = COLOR_RED
        elif low == '</red>':
            current_color = None
        elif low == '<green>':
            current_color = COLOR_GREEN
        elif low == '</green>':
            current_color = None
        elif low == '<msaleh>':
            current_color = COLOR_PURPLE
            is_bold = True
        elif low == '</msaleh>':
            current_color = None
            is_bold = False
        elif low == '<fn>':
            is_fn = True
        elif low == '</fn>':
            is_fn = False
        elif low == '<fm>':
            is_fm = True
        elif low == '</fm>':
            is_fm = False
        elif low.startswith('<') and low.endswith('>'):
            continue
        else:
            run = p.add_run(tok)
            sz = 13.5
            c = current_color
            b = is_bold
            if is_fn:
                sz = 10.5
                c = COLOR_RED
                b = True
            elif is_fm:
                c = COLOR_GREEN
                b = True
            set_r_font(run, size_pt=sz, bold=b, color=c)

# Title & Metadata
p_title = doc.add_paragraph()
set_p_rtl(p_title, WD_ALIGN_PARAGRAPH.CENTER)
r = p_title.add_run("الكافي")
set_r_font(r, size_pt=24, bold=True, color=COLOR_BLUE)

p_part = doc.add_paragraph()
set_p_rtl(p_part, WD_ALIGN_PARAGRAPH.CENTER)
r = p_part.add_run("الجزء الأول")
set_r_font(r, size_pt=18, bold=True, color=COLOR_PAGE_BADGE)

p_author = doc.add_paragraph()
set_p_rtl(p_author, WD_ALIGN_PARAGRAPH.CENTER)
r = p_author.add_run("الشيخ محمد بن يعقوب الكليني (قدس سره)")
set_r_font(r, size_pt=15, bold=False, color=COLOR_DARK_GRAY)

doc.add_page_break()

# TOC Page
p_toc_head = doc.add_paragraph()
set_p_rtl(p_toc_head, WD_ALIGN_PARAGRAPH.CENTER)
r = p_toc_head.add_run("فهرس محتويات الجزء الأول")
set_r_font(r, size_pt=18, bold=True, color=COLOR_BLUE)

table = doc.add_table(rows=1, cols=2)
table.autofit = False
hdr_cells = table.rows[0].cells
hdr_cells[0].text = "الصفحة"
hdr_cells[1].text = "العنوان والموضوع"
for cell in hdr_cells:
    for cp in cell.paragraphs:
        set_p_rtl(cp, WD_ALIGN_PARAGRAPH.CENTER)
        for cr in cp.runs:
            set_r_font(cr, size_pt=13, bold=True, color=COLOR_BLUE)

for t in toc:
    row_cells = table.add_row().cells
    row_cells[0].text = str(t[0])
    indent = "    " * (t[2] - 1) if t[2] > 1 else ""
    row_cells[1].text = clean_xml(f"{indent}{t[1]}")
    for cp in row_cells[0].paragraphs:
        set_p_rtl(cp, WD_ALIGN_PARAGRAPH.CENTER)
        for cr in cp.runs:
            set_r_font(cr, size_pt=11.5, bold=False)
    for cp in row_cells[1].paragraphs:
        set_p_rtl(cp, WD_ALIGN_PARAGRAPH.RIGHT)
        for cr in cp.runs:
            bld = (t[2] == 1)
            clr = COLOR_BLUE if bld else None
            set_r_font(cr, size_pt=12 if bld else 11, bold=bld, color=clr)

doc.add_page_break()

# Body Pages
for page_id, text in pages:
    p_badge = doc.add_paragraph()
    set_p_rtl(p_badge, WD_ALIGN_PARAGRAPH.CENTER)
    r = p_badge.add_run(f"❖  الجزء الأول - صفحة {page_id}  ❖")
    set_r_font(r, size_pt=11, bold=True, color=COLOR_PAGE_BADGE)

    lines = (text or "").split('\n')
    for line in lines:
        line_s = clean_xml(line.strip())
        if not line_s:
            continue
        if line_s.startswith('<psm>') and line_s.endswith('</psm>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.CENTER)
            content = re.sub(r'</?psm>', '', line_s)
            run = p.add_run(content)
            set_r_font(run, size_pt=16, bold=True, color=COLOR_GREEN)
        elif line_s.startswith('<head1>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            content = re.sub(r'</?head1>', '', line_s)
            run = p.add_run(content)
            set_r_font(run, size_pt=15, bold=True, color=COLOR_BLUE)
        elif line_s.startswith('<head2>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            content = re.sub(r'</?head2>', '', line_s)
            run = p.add_run(content)
            set_r_font(run, size_pt=14, bold=True, color=COLOR_RED)
        elif line_s.startswith('<fnote>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            content = re.sub(r'</?fnote>', '', line_s)
            run = p.add_run(content)
            set_r_font(run, size_pt=10.5, bold=False, color=COLOR_DARK_GRAY)
        else:
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            render_html_tokens(p, line_s)

os.makedirs(r"d:\01_Projects\mobile\nots\كتب_المكتبة_docx", exist_ok=True)
out_file = r"d:\01_Projects\mobile\nots\كتب_المكتبة_docx\الكافي_الجزء_الأول.docx"
doc.save(out_file)
print(f"Part 1 exported and saved successfully in {time.time() - t0:.2f}s! File size: {os.path.getsize(out_file) / 1024:.1f} KB")

conn.close()
conn_lib.close()
