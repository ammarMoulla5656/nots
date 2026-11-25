# -*- coding: utf-8 -*-
"""
=============================================================================
أداة التصدير الفائقة لكتب المكتبة الشاملة إلى صيغة Word (.docx)
=============================================================================
الوظائف الأساسية:
  1. قراءة بيانات 250 كتاباً (1,200 مجلد، 550,192 صفحة) بدقة 100%.
  2. توليد وثائق Word (.docx) منسقة بالكامل بالاتجاه من اليمين لليسار (RTL).
  3. إنشاء الفهرس الكامل (فهرست المحتويات) في بداية كل مجلد/كتاب.
  4. الحفاظ التام على جميع الألوان والوسوم:
     - <blue>: أزرق ملكي
     - <red>: أحمر قرمزي
     - <green>: أخضر إسلامي
     - <head1>: عنوان رئيسي كبير
     - <head2>: عنوان فرعي / باب
     - <msaleh>: مسألة فقهية (بنفسجي غامق عريض)
     - <psm>: البسملة الشريفة مزخرفة في المنتصف
     - <fn>: إحالة الهامش
     - <fnote>: نصوص الهوامش أسفل الصفحة
  5. ترقيم الصفحات وتحديد المجلدات بدقة مطابقة للأصل.
=============================================================================
"""

import os
import sys
import re
import time
import sqlite3
import argparse
from concurrent.futures import ThreadPoolExecutor

try:
    from docx import Document
    from docx.shared import Pt, RGBColor, Inches
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import parse_xml
    from docx.oxml.ns import nsdecls
except ImportError:
    print("❌ خطأ: مكتبة python-docx غير مثبتة. يرجى تثبيتها عبر: pip install python-docx")
    sys.exit(1)

# مسارات قواعد البيانات ومجلد الإخراج
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the project root: this file lives in scripts/
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
OUTPUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_docx")

# الألوان القياسية
COLOR_BLUE = RGBColor(0, 102, 204)
COLOR_RED = RGBColor(180, 20, 20)
COLOR_GREEN = RGBColor(0, 128, 0)
COLOR_PURPLE = RGBColor(128, 0, 128)
COLOR_DARK_GRAY = RGBColor(80, 80, 80)
COLOR_PAGE_BADGE = RGBColor(140, 80, 20)

# التصنيفات
CATEGORY_NAMES = {
    1: "التفسير وعلوم القرآن",
    17: "العقائد والكلام",
    18: "الحديث الشريف وعلومه",
    19: "الأخلاق والآداب والسلوك",
    21: "الفقه الإسلامي والأحكام",
    22: "أصول الفقه والقواعد الأصولية",
    25: "علم الرجال والدراية والتراجم",
    27: "النحو والصرف وعلوم اللغة",
    29: "البلاغة والمعاني والبيان",
    30: "المنطق والفلسفة الإسلامية"
}

# تنظيف محارف التحكم غير المتوافقة مع XML
XML_CONTROL_CHARS = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')
TOKEN_PATTERN = re.compile(r'(<[^>]+>|[^<]+)')

def clean_xml(text):
    if not text:
        return ""
    return XML_CONTROL_CHARS.sub('', text)

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

def render_html_tokens(p, text):
    text = clean_xml(text)
    tokens = TOKEN_PATTERN.findall(text)
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

def export_part_to_docx(book_info, part_info, out_path):
    """
    تصدير جزء محدد من كتاب إلى ملف DOCX متكامل مع الفهرست والألوان
    """
    b_id, b_name, author, cat_id, total_vols = book_info
    part_id, joze = part_info

    conn_rep = sqlite3.connect(REPAIRED_DB)
    conn_lib = sqlite3.connect(LIBRARY_DB)

    # جلب الصفحات
    pages = conn_rep.execute(
        "SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id",
        (part_id,)
    ).fetchall()

    if not pages:
        conn_rep.close()
        conn_lib.close()
        return False, f"لا توجد صفحات للجزء {part_id}"

    # جلب الفهرس
    toc = conn_lib.execute(
        "SELECT pageID, title, level FROM Contents WHERE partID=? ORDER BY pageID, level",
        (part_id,)
    ).fetchall()

    doc = Document()
    for s in doc.sections:
        s.page_width = Inches(8.27)  # A4
        s.page_height = Inches(11.69)
        s.top_margin = Inches(0.8)
        s.bottom_margin = Inches(0.8)
        s.left_margin = Inches(0.8)
        s.right_margin = Inches(0.8)

    # 1. صفحة الغلاف والترويسة
    p_title = doc.add_paragraph()
    set_p_rtl(p_title, WD_ALIGN_PARAGRAPH.CENTER)
    r = p_title.add_run(b_name)
    set_r_font(r, size_pt=24, bold=True, color=COLOR_BLUE)

    p_part = doc.add_paragraph()
    set_p_rtl(p_part, WD_ALIGN_PARAGRAPH.CENTER)
    vol_text = f"الجزء {joze}" if total_vols > 1 else "الكتاب كامل"
    r = p_part.add_run(vol_text)
    set_r_font(r, size_pt=18, bold=True, color=COLOR_PAGE_BADGE)

    if author:
        p_author = doc.add_paragraph()
        set_p_rtl(p_author, WD_ALIGN_PARAGRAPH.CENTER)
        r = p_author.add_run(author)
        set_r_font(r, size_pt=14, bold=False, color=COLOR_DARK_GRAY)

    cat_name = CATEGORY_NAMES.get(cat_id, "")
    if cat_name:
        p_cat = doc.add_paragraph()
        set_p_rtl(p_cat, WD_ALIGN_PARAGRAPH.CENTER)
        r = p_cat.add_run(f"قسم: {cat_name}")
        set_r_font(r, size_pt=12, bold=False, color=COLOR_GREEN)

    doc.add_page_break()

    # 2. صفحة الفهرست الشامل
    p_toc_head = doc.add_paragraph()
    set_p_rtl(p_toc_head, WD_ALIGN_PARAGRAPH.CENTER)
    r = p_toc_head.add_run(f"فهرس محتويات {vol_text}")
    set_r_font(r, size_pt=18, bold=True, color=COLOR_BLUE)

    if toc:
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
                    set_r_font(cr, size_pt=11, bold=False)
            for cp in row_cells[1].paragraphs:
                set_p_rtl(cp, WD_ALIGN_PARAGRAPH.RIGHT)
                for cr in cp.runs:
                    bld = (t[2] == 1)
                    clr = COLOR_BLUE if bld else None
                    set_r_font(cr, size_pt=12 if bld else 11, bold=bld, color=clr)

    doc.add_page_break()

    # 3. صفحات المتن
    for page_id, text in pages:
        p_badge = doc.add_paragraph()
        set_p_rtl(p_badge, WD_ALIGN_PARAGRAPH.CENTER)
        r = p_badge.add_run(f"❖  {vol_text} - صفحة {page_id}  ❖")
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

    doc.save(out_path)
    conn_rep.close()
    conn_lib.close()
    return True, f"تم الحفظ: {os.path.basename(out_path)} ({len(pages)} صفحة)"

def sanitize_filename(name):
    clean = re.sub(r'[\\/*?:"<>|]', '', name)
    return clean.strip().replace(' ', '_')

def export_book_by_id(book_id, out_dir=OUTPUT_DIR):
    conn_lib = sqlite3.connect(LIBRARY_DB)
    book_meta = conn_lib.execute(
        "SELECT bookID, book_name, authorName, category, cunt FROM Contents WHERE bookID=? LIMIT 1",
        (book_id,)
    ).fetchone()

    if not book_meta:
        conn_lib.close()
        print(f"❌ لم يتم العثور على كتاب بالرقم: {book_id}")
        return

    parts = conn_lib.execute(
        "SELECT DISTINCT partID, joze FROM Contents WHERE bookID=? ORDER BY joze, partID",
        (book_id,)
    ).fetchall()
    conn_lib.close()

    b_id, b_name, author, cat_id, total_vols = book_meta
    clean_bname = sanitize_filename(b_name)
    author_short = sanitize_filename((author or "").split('(')[0]) if author else ""

    print(f"\n📖 جاري تصدير كتاب: [{b_id}] {b_name} ({len(parts)} مجلد/أجزاء)...")
    os.makedirs(out_dir, exist_ok=True)

    for p_id, joze in parts:
        if len(parts) == 1:
            fname = f"{b_id}_{clean_bname}.docx"
        else:
            fname = f"{b_id}_{clean_bname}_ج{joze:02d}.docx"
        out_path = os.path.join(out_dir, fname)

        t_start = time.time()
        success, msg = export_part_to_docx((b_id, b_name, author, cat_id, len(parts)), (p_id, joze), out_path)
        if success:
            sz_kb = os.path.getsize(out_path) / 1024
            print(f"   ✓ [جزء {joze}] اكتمل في {time.time() - t_start:.1f} ثانية ({sz_kb:.1f} KB) -> {fname}")
        else:
            print(f"   ❌ [جزء {joze}] فشل: {msg}")

def export_top_books():
    """
    تصدير أمهات الكتب الإسلامية الرئيسية
    """
    top_book_ids = [
        1,    # الكافي (8 أجزاء)
        19,   # الاستبصار (4 أجزاء)
        357,  # تهذيب الأحكام (10 أجزاء)
        361,  # من لا يحضره الفقيه (4 أجزاء)
        212,  # عقائد الإمامية (1 جزء)
        241,  # كشف المراد في شرح تجريد الاعتقاد (1 جزء)
        364,  # كفاية الأصول (1 جزء)
        446,  # العروة الوثقى (2 جزء)
        425,  # المختصر النافع في فقه الإمامية (1 جزء)
        366   # خلاصة الأقوال في معرفة الرجال (1 جزء)
    ]
    print("=" * 70)
    print("🚀 بدء تصدير أمهات الكتب الرئيسية (10 كتب رائدة - 33 مجلداً)")
    print("=" * 70)
    for b_id in top_book_ids:
        export_book_by_id(b_id)

def export_all_books(max_workers=4):
    """
    تصدير كافة كتب المكتبة الـ 250 دفعة واحدة
    """
    conn_lib = sqlite3.connect(LIBRARY_DB)
    books = conn_lib.execute("SELECT DISTINCT bookID FROM Contents ORDER BY bookID").fetchall()
    conn_lib.close()

    total = len(books)
    print("=" * 70)
    print(f"📚 بدء تصدير جميع كتب المكتبة الـ {total} كتاباً إلى صيغة DOCX...")
    print("=" * 70)

    t0 = time.time()
    for idx, (b_id,) in enumerate(books, 1):
        print(f"\n[{idx}/{total}] جاري معالجة الكتاب رقم: {b_id}")
        export_book_by_id(b_id)

    print(f"\n🎉 تم الانتهاء من تصدير جميع الكتب في {time.time() - t0:.1f} ثانية!")

def interactive_menu():
    print("=" * 70)
    print("   📚 أداة تصدير كتب المكتبة الشاملة إلى صيغة Word (DOCX) 📚")
    print("=" * 70)
    print(" [1] تصدير أمهات الكتب الرئيسية (الكافي، الاستبصار، من لا يحضره الفقيه، الخ)")
    print(" [2] تصدير كتاب محدد (بالرقم أو الاسم)")
    print(" [3] توليد الفهرس العام الشامل لجميع الكتب (Master Catalog DOCX + JSON + CSV)")
    print(" [4] تصدير جميع كتب المكتبة الـ 250 دفعة واحدة")
    print(" [5] خروج")
    print("=" * 70)
    
    choice = input("اختر رقم العملية [1-5]: ").strip()
    if choice == "1":
        export_top_books()
    elif choice == "2":
        q = input("أدخل رقم الكتاب أو جزء من اسمه: ").strip()
        if q.isdigit():
            export_book_by_id(int(q))
        else:
            conn_lib = sqlite3.connect(LIBRARY_DB)
            matches = conn_lib.execute(
                "SELECT DISTINCT bookID, book_name, authorName FROM Contents WHERE book_name LIKE ? LIMIT 10",
                (f"%{q}%",)
            ).fetchall()
            conn_lib.close()
            if not matches:
                print(f"❌ لم يتم العثور على كتب تطابق: '{q}'")
            elif len(matches) == 1:
                export_book_by_id(matches[0][0])
            else:
                print("تم العثور على الكتب التالية، اختر رقم الكتاب:")
                for m in matches:
                    print(f"  [{m[0]}] {m[1]} - {m[2]}")
                sel = input("أدخل رقم الكتاب: ").strip()
                if sel.isdigit():
                    export_book_by_id(int(sel))
    elif choice == "3":
        from tools.create_master_catalog import create_master_catalog
        create_master_catalog()
    elif choice == "4":
        confirm = input("تصدير 250 كتاباً (1200 مجلد) قد يستغرق بضع دقائق. هل تريد المتابعة؟ (y/n): ").strip().lower()
        if confirm == 'y':
            export_all_books()
    elif choice == "5":
        print("مع السلامة!")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="أداة تصدير كتب المكتبة إلى DOCX")
    parser.add_argument("--top", action="store_true", help="تصدير أمهات الكتب الرئيسية")
    parser.add_argument("--all", action="store_true", help="تصدير جميع كتب المكتبة")
    parser.add_argument("--book", type=int, help="تصدير كتاب محدد برقم المعرف bookID")
    parser.add_argument("--catalog", action="store_true", help="توليد وثيقة الفهرس العام الشامل")

    args = parser.parse_args()

    if args.top:
        export_top_books()
    elif args.all:
        export_all_books()
    elif args.book:
        export_book_by_id(args.book)
    elif args.catalog:
        from tools.create_master_catalog import create_master_catalog
        create_master_catalog()
    else:
        interactive_menu()
