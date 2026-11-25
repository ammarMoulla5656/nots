import sqlite3
import time
import re
import os
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls, qn

t0 = time.time()
db_path = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"
lib_path = r"d:\01_Projects\mobile\nots\library.db"

conn = sqlite3.connect(db_path)
conn_lib = sqlite3.connect(lib_path)

pages = conn.execute("SELECT page_id, text FROM BookPages WHERE part_id=1 ORDER BY page_id").fetchall()
toc = conn_lib.execute("SELECT pageID, title, level FROM Contents WHERE partID=1 ORDER BY pageID, level").fetchall()

doc = Document()

# Set default document font to Traditional Arabic
normal_style = doc.styles['Normal']
normal_style.font.name = 'Traditional Arabic'
normal_style.font.size = Pt(13.5)
rPr = normal_style._element.get_or_add_rPr()
rPr.append(parse_xml(r'<w:rFonts %s w:ascii="Traditional Arabic" w:hAnsi="Traditional Arabic" w:cs="Traditional Arabic"/>' % nsdecls('w')))
pPr = normal_style._element.get_or_add_pPr()
pPr.append(OxmlElement('w:bidi'))

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

def set_p_rtl(p, align=WD_ALIGN_PARAGRAPH.RIGHT):
    pPr = p._element.get_or_add_pPr()
    pPr.append(OxmlElement('w:bidi'))
    p.alignment = align

def render_html_tokens(p, text):
    tokens = token_pattern.findall(clean_xml(text))
    cur_c = None
    bld = False
    is_fn = False
    is_fm = False
    
    for tok in tokens:
        if not tok:
            continue
        low = tok.lower()
        if low == '<blue>':
            cur_c = COLOR_BLUE
        elif low == '</blue>':
            cur_c = None
        elif low == '<red>':
            cur_c = COLOR_RED
        elif low == '</red>':
            cur_c = None
        elif low == '<green>':
            cur_c = COLOR_GREEN
        elif low == '</green>':
            cur_c = None
        elif low == '<msaleh>':
            cur_c = COLOR_PURPLE
            bld = True
        elif low == '</msaleh>':
            cur_c = None
            bld = False
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
            # Add RTL flag to run
            run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            if is_fn:
                run.font.size = Pt(10.5)
                run.font.color.rgb = COLOR_RED
                run.bold = True
            elif is_fm:
                run.font.color.rgb = COLOR_GREEN
                run.bold = True
            else:
                if cur_c:
                    run.font.color.rgb = cur_c
                if bld:
                    run.bold = True

# Title
p_title = doc.add_paragraph()
set_p_rtl(p_title, WD_ALIGN_PARAGRAPH.CENTER)
r = p_title.add_run("الكافي")
r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
r.font.size = Pt(24)
r.bold = True
r.font.color.rgb = COLOR_BLUE

p_part = doc.add_paragraph()
set_p_rtl(p_part, WD_ALIGN_PARAGRAPH.CENTER)
r = p_part.add_run("الجزء الأول")
r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
r.font.size = Pt(18)
r.bold = True
r.font.color.rgb = COLOR_PAGE_BADGE

doc.add_page_break()

# TOC
p_toc_head = doc.add_paragraph()
set_p_rtl(p_toc_head, WD_ALIGN_PARAGRAPH.CENTER)
r = p_toc_head.add_run("فهرس محتويات الجزء الأول")
r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
r.font.size = Pt(18)
r.bold = True
r.font.color.rgb = COLOR_BLUE

table = doc.add_table(rows=1, cols=2)
table.autofit = False
hdr_cells = table.rows[0].cells
hdr_cells[0].text = "الصفحة"
hdr_cells[1].text = "العنوان والموضوع"
for cell in hdr_cells:
    for cp in cell.paragraphs:
        set_p_rtl(cp, WD_ALIGN_PARAGRAPH.CENTER)
        for cr in cp.runs:
            cr._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            cr.font.size = Pt(13)
            cr.bold = True
            cr.font.color.rgb = COLOR_BLUE

for t in toc:
    row_cells = table.add_row().cells
    row_cells[0].text = str(t[0])
    indent = "    " * (t[2] - 1) if t[2] > 1 else ""
    row_cells[1].text = clean_xml(f"{indent}{t[1]}")
    for cp in row_cells[0].paragraphs:
        set_p_rtl(cp, WD_ALIGN_PARAGRAPH.CENTER)
        for cr in cp.runs:
            cr._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            cr.font.size = Pt(11)
    for cp in row_cells[1].paragraphs:
        set_p_rtl(cp, WD_ALIGN_PARAGRAPH.RIGHT)
        for cr in cp.runs:
            cr._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            bld = (t[2] == 1)
            cr.font.size = Pt(12 if bld else 11)
            cr.bold = bld
            if bld:
                cr.font.color.rgb = COLOR_BLUE

doc.add_page_break()

# Pages
for page_id, text in pages:
    p_badge = doc.add_paragraph()
    set_p_rtl(p_badge, WD_ALIGN_PARAGRAPH.CENTER)
    r = p_badge.add_run(f"❖  الجزء الأول - صفحة {page_id}  ❖")
    r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
    r.font.size = Pt(11)
    r.bold = True
    r.font.color.rgb = COLOR_PAGE_BADGE

    for line in (text or "").split('\n'):
        line_s = clean_xml(line.strip())
        if not line_s:
            continue
        if line_s.startswith('<psm>') and line_s.endswith('</psm>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.CENTER)
            content = re.sub(r'</?psm>', '', line_s)
            run = p.add_run(content)
            run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            run.font.size = Pt(16)
            run.bold = True
            run.font.color.rgb = COLOR_GREEN
        elif line_s.startswith('<head1>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            content = re.sub(r'</?head1>', '', line_s)
            run = p.add_run(content)
            run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            run.font.size = Pt(15)
            run.bold = True
            run.font.color.rgb = COLOR_BLUE
        elif line_s.startswith('<head2>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            content = re.sub(r'</?head2>', '', line_s)
            run = p.add_run(content)
            run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            run.font.size = Pt(14)
            run.bold = True
            run.font.color.rgb = COLOR_RED
        elif line_s.startswith('<fnote>'):
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            content = re.sub(r'</?fnote>', '', line_s)
            run = p.add_run(content)
            run._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            run.font.size = Pt(10.5)
            run.font.color.rgb = COLOR_DARK_GRAY
        else:
            p = doc.add_paragraph()
            set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
            render_html_tokens(p, line_s)

out_file = r"d:\01_Projects\mobile\nots\tools\test_fast.docx"
doc.save(out_file)
print(f"Exported in {time.time() - t0:.2f}s! File size: {os.path.getsize(out_file) / 1024:.1f} KB")

conn.close()
conn_lib.close()
