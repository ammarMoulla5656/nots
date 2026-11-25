# -*- coding: utf-8 -*-
"""
=============================================================================
أداة تجزئة ملف PDF ومطابقته صفحة بصفحة مع نصوص Word (DOCX)
كتاب: المقاصد النحوية في شرح شواهد شروح الألفية (بدر الدين العيني)
=============================================================================
الوظيفة:
  1. تجزئة ملف PDF الشامل (2247 صفحة) إلى 4 مجلدات PDF مستقلة.
  2. إنشاء ملفات Word DOCX متطابقة 1:1 مع صفحات الـ PDF والنسخة المطبوعة.
  3. الصفحة رقم 40 في DOCX هي تماماً الصفحة 40 في PDF والمطبوع.
  4. في حال كانت الصفحة غير موجودة في النص الرقمي (مثل صفحات الفهارس 5-8)،
     يتم جعل الصفحة فارغة مع تنبيه لطيف لحفظ الترقيم والمطابقة التامة.
=============================================================================
"""

import os
import sys
import re
import json
import time
import argparse

try:
    import fitz  # PyMuPDF
except ImportError:
    print("جاري تثبيت pymupdf...")
    os.system(f'"{sys.executable}" -m pip install pymupdf')
    import fitz

try:
    import docx
    from docx.shared import Pt, Inches, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import parse_xml
    from docx.oxml.ns import nsdecls
except ImportError:
    print("جاري تثبيت python-docx...")
    os.system(f'"{sys.executable}" -m pip install python-docx')
    import docx
    from docx.shared import Pt, Inches, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import parse_xml
    from docx.oxml.ns import nsdecls

try:
    from bs4 import BeautifulSoup, NavigableString, Tag
except ImportError:
    print("جاري تثبيت beautifulsoup4...")
    os.system(f'"{sys.executable}" -m pip install beautifulsoup4')
    from bs4 import BeautifulSoup, NavigableString, Tag

# =============================================================================
# ثوابت وتقسيمات المجلدات الأربعة للكتاب (مطابقة لفهرس PDF المطبوع)
# =============================================================================
DEFAULT_PDF_PATH = r"C:\Users\pc\Desktop\601511541495714938.pdf"
CACHE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".cache_ketab", "book_2119")

# نطاقات صفحات المجلدات الأربعة في ملف PDF الأصلي (ترقيم يبدأ من 1):
# المجلد 1: من صفحة 1 إلى 568 (568 صفحة)
# المجلد 2: من صفحة 569 إلى 1000 (432 صفحة)
# المجلد 3: من صفحة 1001 إلى 1488 (488 صفحة)
# المجلد 4: من صفحة 1489 إلى 2247 (759 صفحة)
VOLUMES_CONFIG = [
    {
        "vol_num": 1,
        "name": "المجلد الأول",
        "start_page": 1,
        "end_page": 568,
        "total_pages": 568
    },
    {
        "vol_num": 2,
        "name": "المجلد الثاني",
        "start_page": 569,
        "end_page": 1000,
        "total_pages": 432
    },
    {
        "vol_num": 3,
        "name": "المجلد الثالث",
        "start_page": 1001,
        "end_page": 1488,
        "total_pages": 488
    },
    {
        "vol_num": 4,
        "name": "المجلد الرابع",
        "start_page": 1489,
        "end_page": 2247,
        "total_pages": 759
    }
]

# =============================================================================
# دوال التنسيق المتقدم للغة العربية في Word DOCX
# =============================================================================
def set_p_rtl(p):
    """ضبط اتجاه الفقرة من اليمين إلى اليسار مع المحاذاة لليمين"""
    p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    pPr = p._p.get_or_add_pPr()
    pPr.append(parse_xml(r'<w:bidi %s w:val="1"/>' % nsdecls('w')))

def add_rtl_run(p, text, font_name="Traditional Arabic", size=12.5, bold=False, italic=False, color=None, superscript=False):
    """إضافة نص مع تطبيق خصائص الخط العربي والاتجاه"""
    run = p.add_run(text)
    run.bold = bold
    run.italic = italic
    run.font.name = font_name
    run.font.size = Pt(size)
    if color:
        run.font.color.rgb = color
    if superscript:
        run.font.superscript = True

    rPr = run._r.get_or_add_rPr()
    rPr.append(parse_xml(r'<w:rtl %s w:val="1"/>' % nsdecls('w')))
    rPr.append(parse_xml(r'<w:rFonts %s w:ascii="%s" w:hAnsi="%s" w:cs="%s"/>' % (nsdecls('w'), font_name, font_name, font_name)))
    return run

def configure_section_a4_rtl(section):
    """إعداد هوامش وحجم الصفحة A4 مع دعم RTL لضمان استيعاب الصفحة الواحدة"""
    section.page_width = Inches(8.27)
    section.page_height = Inches(11.69)
    # هوامش مدمجة ومريحة (0.65 بوصة) لتتسع الصفحة الواحدة لكل محتواها دون انزلاق
    section.top_margin = Inches(0.65)
    section.bottom_margin = Inches(0.65)
    section.left_margin = Inches(0.65)
    section.right_margin = Inches(0.65)
    
    sectPr = section._sectPr
    sectPr.append(parse_xml(r'<w:bidi %s w:val="1"/>' % nsdecls('w')))

def extract_text_runs(tag, current_style=None):
    """استخراج النصوص وتنسيقات الآيات والشواهد والهوامش"""
    if current_style is None:
        current_style = {}
    runs = []
    for child in tag.contents:
        if isinstance(child, NavigableString):
            txt = str(child)
            if txt:
                runs.append((txt, dict(current_style)))
        elif isinstance(child, Tag):
            new_style = dict(current_style)
            classes = child.get("class", [])
            
            if "g-copy" in classes or child.name == "i":
                continue
                
            if "g-footnote-link" in classes:
                new_style["footnote"] = True
                new_style["superscript"] = True
                new_style["bold"] = True
                new_style["color"] = RGBColor(0, 102, 204)
                new_style["size"] = 9.5
            elif "g-footnote-target" in classes:
                new_style["bold"] = True
                new_style["color"] = RGBColor(0, 102, 204)
            elif "g-aya" in classes:
                new_style["bold"] = True
                new_style["color"] = RGBColor(0, 128, 0) # لون أخضر للآيات
            elif "g-quotes" in classes:
                new_style["italic"] = True
                
            runs.extend(extract_text_runs(child, new_style))
    return runs

def render_page_content(doc, page_data, vol_num, page_in_vol, master_page):
    """تنسيق محتوى صفحة واحدة أو إدراج صفحة فارغة عند عدم توفر النص"""
    # 1. ترويسة الصفحة بالأرقام المزدوجة (رقم المجلد والرقم المتسلسل)
    p_hdr = doc.add_paragraph()
    set_p_rtl(p_hdr)
    p_hdr.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_hdr.paragraph_format.space_before = Pt(0)
    p_hdr.paragraph_format.space_after = Pt(4)
    
    if vol_num == 1:
        hdr_label = f"--- [ المجلد 1 | الصفحة: {page_in_vol} ] ---"
    else:
        hdr_label = f"--- [ المجلد {vol_num} | صفحة المجلد: {page_in_vol} | الترقيم المتسلسل: {master_page} ] ---"
        
    add_rtl_run(p_hdr, hdr_label, font_name="Traditional Arabic", size=10, bold=True, color=RGBColor(130, 130, 130))

    # إذا كانت الصفحة غير متوفرة في الأصل الرقمي (فهرس المطبوع أو بياض):
    if not page_data or not page_data.get("content"):
        p_blank = doc.add_paragraph()
        set_p_rtl(p_blank)
        p_blank.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p_blank.paragraph_format.space_before = Pt(160)
        p_blank.paragraph_format.space_after = Pt(20)
        note = f"[ صفحة {page_in_vol} (متسلسل: {master_page}): فهرس المطبوع / غير مدرج في النص الرقمي ]"
        add_rtl_run(p_blank, note, font_name="Traditional Arabic", size=12, italic=True, color=RGBColor(160, 160, 160))
        return

    # معالجة محتوى HTML
    soup = BeautifulSoup(page_data.get("content", ""), "html.parser")
    for el in soup.find_all(class_="g-copy"):
        el.decompose()
    for el in soup.find_all("i", class_="ico-files"):
        el.decompose()

    footer_div = soup.find("div", class_="g-page-footer")
    if footer_div:
        footer_soup = footer_div.extract()
    else:
        footer_soup = None

    # إضافة العناوين والفقرات
    for el in soup.children:
        if not isinstance(el, Tag):
            continue

        classes = el.get("class", [])
        if "g-title" in classes or el.name in ["h1", "h2", "h3", "h4"]:
            title_text = el.get_text().strip()
            if title_text:
                p_t = doc.add_paragraph()
                set_p_rtl(p_t)
                p_t.paragraph_format.space_before = Pt(4)
                p_t.paragraph_format.space_after = Pt(2)
                add_rtl_run(p_t, title_text, font_name="Traditional Arabic", size=14, bold=True, color=RGBColor(150, 20, 20))
            continue

        if "g-paragraph" in classes or el.name == "p":
            runs = extract_text_runs(el)
            if not runs:
                continue

            p_p = doc.add_paragraph()
            set_p_rtl(p_p)
            p_p.paragraph_format.space_before = Pt(1)
            p_p.paragraph_format.space_after = Pt(2)
            p_p.paragraph_format.line_spacing = 1.15

            for text, style in runs:
                add_rtl_run(
                    p_p,
                    text,
                    font_name="Traditional Arabic",
                    size=style.get("size", 12),
                    bold=style.get("bold", False),
                    italic=style.get("italic", False),
                    color=style.get("color", None),
                    superscript=style.get("superscript", False)
                )

    # معالجة هوامش الصفحة
    if footer_soup:
        fn_paragraphs = footer_soup.find_all("p", class_="g-paragraph")
        if fn_paragraphs:
            p_sep = doc.add_paragraph()
            set_p_rtl(p_sep)
            p_sep.paragraph_format.space_before = Pt(4)
            p_sep.paragraph_format.space_after = Pt(1)
            add_rtl_run(p_sep, "____________________________________", size=8, color=RGBColor(180, 180, 180))

            for fn_p in fn_paragraphs:
                fn_runs = extract_text_runs(fn_p)
                if not fn_runs:
                    continue

                p_f = doc.add_paragraph()
                set_p_rtl(p_f)
                p_f.paragraph_format.space_before = Pt(1)
                p_f.paragraph_format.space_after = Pt(1)
                p_f.paragraph_format.line_spacing = 1.1

                for text, style in fn_runs:
                    color = style.get("color") or RGBColor(60, 60, 60)
                    add_rtl_run(
                        p_f,
                        text,
                        font_name="Traditional Arabic",
                        size=10,
                        bold=style.get("bold", False),
                        italic=style.get("italic", False),
                        color=color,
                        superscript=style.get("superscript", False)
                    )

# =============================================================================
# العمليات الرئيسية: تجزئة الـ PDF وإنشاء الـ DOCX المطابق
# =============================================================================
def split_pdf_file(input_pdf_path, output_dir):
    """تجزئة ملف الـ PDF الشامل إلى 4 مجلدات مستقلة"""
    print("\n" + "=" * 70)
    print("✂️  [المرحلة 1] تجزئة ملف PDF إلى المجلدات الأربعة...")
    print("=" * 70)

    if not os.path.exists(input_pdf_path):
        raise FileNotFoundError(f"لم يتم العثور على ملف PDF في: {input_pdf_path}")

    os.makedirs(output_dir, exist_ok=True)
    src_doc = fitz.open(input_pdf_path)
    total_src_pages = len(src_doc)
    print(f"📖 إجمالي صفحات ملف PDF الأصلي: {total_src_pages} صفحة.")

    split_results = []
    for cfg in VOLUMES_CONFIG:
        vol_num = cfg["vol_num"]
        start_p = cfg["start_page"]
        end_p = cfg["end_page"]
        
        # تحويل إلى 0-indexed
        from_idx = start_p - 1
        to_idx = min(end_p - 1, total_src_pages - 1)
        
        vol_pdf = fitz.open()
        vol_pdf.insert_pdf(src_doc, from_page=from_idx, to_page=to_idx)
        
        out_name = f"المقاصد النحوية - المجلد {vol_num}.pdf"
        out_path = os.path.join(output_dir, out_name)
        vol_pdf.save(out_path)
        
        page_count = len(vol_pdf)
        size_mb = os.path.getsize(out_path) / (1024 * 1024)
        print(f"✅ المجلد {vol_num}: الصفحات {start_p} إلى {end_p} ({page_count} صفحة) -> {out_name} ({size_mb:.1f} MB)")
        split_results.append((vol_num, out_path, page_count))

    src_doc.close()
    return split_results

def load_cached_pages_map(cache_dir):
    """تحميل فهرس الصفحات الرقمية من التخزين المؤقت"""
    print("\n" + "=" * 70)
    print("📥 [المرحلة 2] تحميل النصوص الرقمية وربطها بأرقام صفحات PDF...")
    print("=" * 70)

    if not os.path.exists(cache_dir):
        raise FileNotFoundError(f"مجلد التخزين المؤقت غير موجود: {cache_dir}")

    files = [f for f in os.listdir(cache_dir) if f.endswith(".json")]
    print(f"📦 تم العثور على {len(files)} صفحة نصية مخزنة مؤقتاً.")

    page_map = {}
    for f in files:
        fpath = os.path.join(cache_dir, f)
        try:
            with open(fpath, "r", encoding="utf-8") as fp:
                d = json.load(fp)
                p = d.get("page")
                pid = d.get("id")
                # إذا كانت الصفحة 0 تكون غلاف المجلد المقابل لـ id
                target_p = pid if (p == 0 or p is None) else p
                page_map[target_p] = d
        except Exception:
            pass

    print(f"🎯 تم ربط {len(page_map)} صفحة بنجاح مع أرقام صفحات المطبوع وPDF.")
    return page_map

def generate_matched_docx(page_map, output_dir):
    """إنشاء ملفات DOCX الأربعة متطابقة تماماً 1:1 مع صفحات PDF والمطبوع"""
    print("\n" + "=" * 70)
    print("📝 [المرحلة 3] إنشاء ملفات Word DOCX المطابقة بنسبة 100% للصفحات...")
    print("=" * 70)

    os.makedirs(output_dir, exist_ok=True)
    docx_results = []

    for cfg in VOLUMES_CONFIG:
        vol_num = cfg["vol_num"]
        vol_name = cfg["name"]
        start_page = cfg["start_page"]
        end_page = cfg["end_page"]
        expected_total = cfg["total_pages"]

        print(f"\n🚀 جاري بناء [{vol_name}] (الصفحات {start_page} إلى {end_page} - إجمالي {expected_total} صفحة)...")
        doc = docx.Document()
        configure_section_a4_rtl(doc.sections[0])

        current_vol_pages = list(range(start_page, end_page + 1))
        
        for idx, master_pno in enumerate(current_vol_pages):
            # إدراج فاصل صفحات حقيقي قبل كل صفحة جديدة بعد الأولى
            if idx > 0:
                doc.add_page_break()

            page_in_vol = idx + 1
            page_data = page_map.get(master_pno)

            render_page_content(
                doc=doc,
                page_data=page_data,
                vol_num=vol_num,
                page_in_vol=page_in_vol,
                master_page=master_pno
            )

        out_name = f"المقاصد النحوية - {vol_name} (مطابق لـ PDF بالكامل).docx"
        out_path = os.path.join(output_dir, out_name)
        doc.save(out_path)

        size_mb = os.path.getsize(out_path) / (1024 * 1024)
        print(f"✅ تم حفظ [{vol_name}]: {expected_total} صفحة وورد مطابقة -> {out_name} ({size_mb:.2f} MB)")
        docx_results.append((vol_num, out_path, expected_total))

    return docx_results

# =============================================================================
# الدالة الرئيسية للتشغيل
# =============================================================================
def main():
    parser = argparse.ArgumentParser(description="أداة تجزئة ومطابقة PDF مع Word DOCX صفحة بصفحة")
    parser.add_argument("--pdf", default=DEFAULT_PDF_PATH, help="مسار ملف PDF الشامل")
    parser.add_argument("--pdf-out", default=r"d:\01_Projects\mobile\nots\مجلدات_pdf", help="مجلد حفظ ملفات PDF المجزأة")
    parser.add_argument("--docx-out", default=r"d:\01_Projects\mobile\nots\كتب_مطابقة_docx", help="مجلد حفظ ملفات DOCX المطابقة")

    args = parser.parse_args()

    start_time = time.time()
    print("=" * 70)
    print(" 📚 نظام تجزئة ومطابقة كتاب المقاصد النحوية (PDF <-> DOCX)")
    print("=" * 70)
    print(f"📄 ملف PDF المصدر: {args.pdf}")

    # 1. تجزئة ملف PDF
    split_pdfs = split_pdf_file(args.pdf, args.pdf_out)

    # 2. تحميل خريطة النصوص
    page_map = load_cached_pages_map(CACHE_DIR)

    # 3. توليد ملفات DOCX المطابقة 1:1
    matched_docs = generate_matched_docx(page_map, args.docx_out)

    elapsed = time.time() - start_time
    print("\n" + "=" * 70)
    print(f"🎉 اكتملت العملية بنجاح تام في {elapsed:.1f} ثانية!")
    print("=" * 70)
    print("\n📂 ملفات PDF المجزأة:")
    for v_num, p_path, p_count in split_pdfs:
        print(f"   📕 [المجلد {v_num}]: {os.path.basename(p_path)} ({p_count} صفحة)")

    print("\n📂 ملفات Word DOCX المطابقة تماماً صفحة بصفحة:")
    for v_num, d_path, d_count in matched_docs:
        print(f"   📘 [المجلد {v_num}]: {os.path.basename(d_path)} ({d_count} صفحة)")
    print("=" * 70)

if __name__ == "__main__":
    main()
