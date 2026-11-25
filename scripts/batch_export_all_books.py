# -*- coding: utf-8 -*-
"""
=============================================================================
منظومة التصدير المتوازي الشامل لكافة كتب المكتبة إلى صيغة Word (.docx)
=============================================================================
- تصدير 250 كتاباً (1,200 مجلد، 550,192 صفحة) بالتوازي عبر تعدد العمليات.
- كتابة اسم الكتاب، ID، رقم الجزء، والنوع في اسم الملف.
- تضمين ID الكتاب والنوع في الفهرست وترويسة كل كتاب.
- تلوين كافة النصوص (<blue>, <red>, <green>, <msaleh>, <fn>, <fnote>).
- محاذاة واتجاه عربي كامل (RTL).
=============================================================================
"""

import os
import sys
import re
import time
import sqlite3
from concurrent.futures import ProcessPoolExecutor, as_completed

from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the project root: this file lives in scripts/
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
OUTPUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_docx")
LOG_FILE = os.path.join(BASE_DIR, "export_progress.txt")

COLOR_BLUE = RGBColor(0, 102, 204)
COLOR_RED = RGBColor(180, 20, 20)
COLOR_GREEN = RGBColor(0, 128, 0)
COLOR_PURPLE = RGBColor(128, 0, 128)
COLOR_DARK_GRAY = RGBColor(80, 80, 80)
COLOR_PAGE_BADGE = RGBColor(140, 80, 20)

CATEGORY_SHORT = {
    1: "تفسير_وقرآن",
    17: "عقائد_وكلام",
    18: "حديث_شريف",
    19: "أخلاق_وآداب",
    21: "فقه_وأحكام",
    22: "أصول_فقه",
    25: "رجال_وتراجم",
    27: "نحو_ولغة",
    29: "بلاغة_ومعاني",
    30: "منطق_وفلسفة"
}

CATEGORY_FULL = {
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

XML_CONTROL_CHARS = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')
TOKEN_PATTERN = re.compile(r'(<[^>]+>|[^<]+)')

def clean_xml(text):
    if not text:
        return ""
    return XML_CONTROL_CHARS.sub('', text)

def sanitize_name(name):
    cleaned = re.sub(r'[\\/*?:"<>|]', '', name or '')
    cleaned = re.sub(r'\s+', '_', cleaned.strip())
    return cleaned

def set_p_rtl(p, align=WD_ALIGN_PARAGRAPH.RIGHT):
    pPr = p._element.get_or_add_pPr()
    pPr.append(OxmlElement('w:bidi'))
    p.alignment = align

def render_html_tokens(p, text):
    tokens = TOKEN_PATTERN.findall(clean_xml(text))
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

def export_single_part_worker(task):
    """
    عامل تصدير جزء واحد مستقل
    task = (b_id, b_name, author, cat_id, total_vols, part_id, joze_label, out_path)
    """
    b_id, b_name, author, cat_id, total_vols, part_id, joze_label, out_path = task
    t0 = time.time()
    try:
        # فحص إذا كان الملف موجود مسبقاً وسليم بحجم أكبر من 10 كيلوبايت
        if os.path.exists(out_path) and os.path.getsize(out_path) > 10240:
            return b_id, joze_label, 0, 0, "EXISTS"

        conn_rep = sqlite3.connect(REPAIRED_DB)
        conn_lib = sqlite3.connect(LIBRARY_DB)

        pages = conn_rep.execute(
            "SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id",
            (part_id,)
        ).fetchall()

        if not pages:
            conn_rep.close()
            conn_lib.close()
            return b_id, joze_label, 0, 0, "NO_PAGES"

        toc = conn_lib.execute(
            "SELECT pageID, title, level FROM Contents WHERE partID=? ORDER BY pageID, level",
            (part_id,)
        ).fetchall()

        conn_rep.close()
        conn_lib.close()

        doc = Document()
        for s in doc.sections:
            s.page_width = Inches(8.27)  # A4
            s.page_height = Inches(11.69)
            s.top_margin = Inches(0.8)
            s.bottom_margin = Inches(0.8)
            s.left_margin = Inches(0.8)
            s.right_margin = Inches(0.8)

        # ضبط نمط الفقرة العادية
        norm = doc.styles['Normal']
        norm.font.name = 'Traditional Arabic'
        norm.font.size = Pt(13.5)
        rPr = norm._element.get_or_add_rPr()
        rPr.append(parse_xml(r'<w:rFonts %s w:ascii="Traditional Arabic" w:hAnsi="Traditional Arabic" w:cs="Traditional Arabic"/>' % nsdecls('w')))
        pPr = norm._element.get_or_add_pPr()
        pPr.append(OxmlElement('w:bidi'))

        cat_full = CATEGORY_FULL.get(cat_id, "عام")
        vol_text = f"الجزء {joze_label}" if total_vols > 1 else "الكتاب كامل"

        # 1. الغلاف الرئيسي
        p_title = doc.add_paragraph()
        set_p_rtl(p_title, WD_ALIGN_PARAGRAPH.CENTER)
        r = p_title.add_run(b_name)
        r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
        r.font.size = Pt(24)
        r.bold = True
        r.font.color.rgb = COLOR_BLUE

        p_id = doc.add_paragraph()
        set_p_rtl(p_id, WD_ALIGN_PARAGRAPH.CENTER)
        r = p_id.add_run(f"معرف الكتاب (ID): {b_id}  |  التصنيف والنوع: {cat_full}")
        r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
        r.font.size = Pt(13)
        r.bold = True
        r.font.color.rgb = COLOR_PAGE_BADGE

        p_part = doc.add_paragraph()
        set_p_rtl(p_part, WD_ALIGN_PARAGRAPH.CENTER)
        r = p_part.add_run(vol_text)
        r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
        r.font.size = Pt(18)
        r.bold = True
        r.font.color.rgb = COLOR_BLUE

        if author:
            p_auth = doc.add_paragraph()
            set_p_rtl(p_auth, WD_ALIGN_PARAGRAPH.CENTER)
            r = p_auth.add_run(author)
            r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
            r.font.size = Pt(14)
            r.font.color.rgb = COLOR_DARK_GRAY

        doc.add_page_break()

        # 2. الفهرست التفصيلي
        p_toc_head = doc.add_paragraph()
        set_p_rtl(p_toc_head, WD_ALIGN_PARAGRAPH.CENTER)
        r = p_toc_head.add_run(f"فهرس محتويات {vol_text}  (معرف الكتاب ID: {b_id})")
        r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
        r.font.size = Pt(17)
        r.bold = True
        r.font.color.rgb = COLOR_BLUE

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

        # 3. صفحات الكتاب
        for page_id, text in pages:
            p_badge = doc.add_paragraph()
            set_p_rtl(p_badge, WD_ALIGN_PARAGRAPH.CENTER)
            r = p_badge.add_run(f"❖  [ID: {b_id}] {b_name} - {vol_text} - صفحة {page_id}  ❖")
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

        doc.save(out_path)
        return b_id, joze_label, len(pages), time.time() - t0, None
    except Exception as e:
        return b_id, joze_label, 0, time.time() - t0, str(e)

def build_all_tasks():
    conn_lib = sqlite3.connect(LIBRARY_DB)
    books = conn_lib.execute("""
        SELECT bookID, book_name, authorName, category, cunt 
        FROM Contents 
        GROUP BY bookID 
        ORDER BY bookID
    """).fetchall()

    tasks = []
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    for b in books:
        b_id, b_name, author, cat_id, vol_count = b
        parts_rows = conn_lib.execute("""
            SELECT DISTINCT partID, joze 
            FROM Contents 
            WHERE bookID=? 
            ORDER BY partID
        """, (b_id,)).fetchall()

        total_vols = len(parts_rows)
        clean_bname = sanitize_name(b_name)
        cat_short = CATEGORY_SHORT.get(cat_id, "عام")

        for idx, (p_id, raw_joze) in enumerate(parts_rows, 1):
            if total_vols == 1:
                fname = f"[ID_{b_id:03d}]_[{cat_short}]_[{clean_bname}].docx"
                joze_label = "كامل"
            else:
                if str(raw_joze).isdigit():
                    joze_label = f"{int(raw_joze):02d}"
                elif str(raw_joze) == '-':
                    joze_label = f"{idx:02d}"
                else:
                    joze_label = sanitize_name(str(raw_joze))
                fname = f"[ID_{b_id:03d}]_[{cat_short}]_[{clean_bname}]_ج{joze_label}.docx"

            out_path = os.path.join(OUTPUT_DIR, fname)
            tasks.append((b_id, b_name, author, cat_id, total_vols, p_id, joze_label, out_path))

    conn_lib.close()
    return tasks

def run_batch_export(max_workers=8):
    tasks = build_all_tasks()
    total_tasks = len(tasks)

    print("=" * 75)
    print(" 🚀 انطلاق عملية استخراج وتصدير كافة كتب المكتبة الشاملة دفعة واحدة")
    print("=" * 75)
    print(f"📊 إجمالي المجلدات/الأجزاء المطلوب تصديرها: {total_tasks:,} مجلد")
    print(f"⚙️  عدد المعالجات المتوازية (Workers): {max_workers}")
    print(f"📂 مجلد الحفظ النهائي: {OUTPUT_DIR}")
    print("=" * 75)

    t_start = time.time()
    completed = 0
    total_pages_exported = 0
    errors = []

    with open(LOG_FILE, "w", encoding="utf-8") as f_log:
        f_log.write(f"بدء التصدير: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")

    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        future_map = {executor.submit(export_single_part_worker, task): task for task in tasks}

        for future in as_completed(future_map):
            completed += 1
            task = future_map[future]
            b_id, joze_label, pages_count, duration, err = future.result()

            fname = os.path.basename(task[7])
            total_pages_exported += pages_count

            pct = (completed / total_tasks) * 100
            elapsed = time.time() - t_start
            rate = completed / elapsed if elapsed > 0 else 1
            remaining = (total_tasks - completed) / rate if rate > 0 else 0

            status_str = f"[{completed:4d}/{total_tasks}] ({pct:5.1f}%) | {fname} ({pages_count} صفحة في {duration:.1f}ث)"
            if err:
                status_str += f" | ⚠️ {err}"
                if err != "EXISTS":
                    errors.append((fname, err))

            # print progress every 5 tasks or on completion
            if completed % 5 == 0 or completed == total_tasks or err:
                sys.stdout.write(f"\r⏳ {completed}/{total_tasks} ({pct:.1f}%) | تم تصدير: {total_pages_exported:,} صفحة | متبقي: {remaining/60:.1f} دقيقة ")
                sys.stdout.flush()

            with open(LOG_FILE, "a", encoding="utf-8") as f_log:
                f_log.write(status_str + "\n")

    total_time = time.time() - t_start
    print("\n\n" + "=" * 75)
    print("🎉 تم الانتهاء من تصدير كافة كتب المكتبة بنجاح تام!")
    print("=" * 75)
    print(f"⏱️  إجمالي الوقت المستغرق: {total_time/60:.1f} دقيقة ({total_time:.1f} ثانية)")
    print(f"📖 إجمالي الصفحات المصدرة: {total_pages_exported:,} صفحة")
    print(f"📚 إجمالي الملفات المكتملة: {completed:,} ملف DOCX")
    print(f"❌ الأخطاء إن وجدت: {len(errors)}")
    print("=" * 75)

if __name__ == '__main__':
    run_batch_export(max_workers=8)
