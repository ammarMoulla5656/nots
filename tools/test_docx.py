import re
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import parse_xml
from docx.oxml.ns import nsdecls

# Test parsing text with tags
sample_text = """<psm>بسم الله الرحمن الرحيم</psm>
<head1>(كتاب العقل والجهل)</head1>
١ - أخبرنا<fn>(١)</fn> أبوجعفر محمد بن يعقوب قال: حدثني عدة من أصحابنا منهم محمد بن يحيى العطار، عن أحمد بن محمد، عن الحسن بن محبوب، عن العلاء بن رزين، عن محمد بن مسلم، عن أبي جعفر <fm>(عليه السلام)</fm> قال: لما خلق الله العقل<fn>(٢)</fn> استنطقه ثم قال له:
أقبل فأقبل ثم قال له: أدبر فأدبر<fn>(٣)</fn> ثم قال: وعزتي وجلالي ما خلقت خلقا هو أحب إلي منك ولا أكملتك إلا فيمن احب، أما إني إياك آمر، وإياك أنهى وإياك اعاقب، وإياك اثيب.
<blue>وهذا نص أزرق للتجربة</blue> و<red>هذا نص أحمر</red> و<green>هذا نص أخضر</green>.
<fnote>____________</fnote>
<fnote>(١) الظاهر أن قائل أخبرنا: أحد رواة الكافي رضوان الله عليه.</fnote>
<fnote>(٢) ان العقل هو تعقل الاشياء وفهمها في اصل اللغة.</fnote>
"""

doc = Document()

# Set RTL section
for s in doc.sections:
    s.page_width = Inches(8.27)  # A4
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

def render_html_tokens(p, text):
    token_pattern = re.compile(r'(<[^>]+>|[^<]+)')
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
            continue # ignore unknown tags
        else:
            run = p.add_run(tok)
            sz = 14
            c = current_color
            b = is_bold
            if is_fn:
                sz = 11
                c = COLOR_RED
                b = True
            elif is_fm:
                c = COLOR_GREEN
                b = True
            set_r_font(run, size_pt=sz, bold=b, color=c)

# Parse line by line
lines = sample_text.split('\n')
for line in lines:
    line_s = line.strip()
    if not line_s:
        continue
    if line_s.startswith('<psm>') and line_s.endswith('</psm>'):
        p = doc.add_paragraph()
        set_p_rtl(p, WD_ALIGN_PARAGRAPH.CENTER)
        content = re.sub(r'</?psm>', '', line_s)
        run = p.add_run(content)
        set_r_font(run, size_pt=18, bold=True, color=COLOR_GREEN)
    elif line_s.startswith('<head1>') and line_s.endswith('</head1>'):
        p = doc.add_paragraph()
        set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
        content = re.sub(r'</?head1>', '', line_s)
        run = p.add_run(content)
        set_r_font(run, size_pt=16, bold=True, color=COLOR_BLUE)
    elif line_s.startswith('<fnote>'):
        p = doc.add_paragraph()
        set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
        content = re.sub(r'</?fnote>', '', line_s)
        run = p.add_run(content)
        set_r_font(run, size_pt=11, bold=False, color=RGBColor(80, 80, 80))
    else:
        p = doc.add_paragraph()
        set_p_rtl(p, WD_ALIGN_PARAGRAPH.RIGHT)
        render_html_tokens(p, line_s)

test_path = r"d:\01_Projects\mobile\nots\tools\test_output.docx"
doc.save(test_path)
print("Saved test document successfully to:", test_path)
