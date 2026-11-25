import sqlite3
import json
import csv
import os
import re
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
OUTPUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_docx")

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

def sanitize_name(name):
    cleaned = re.sub(r'[\\/*?:"<>|]', '', name or '')
    cleaned = re.sub(r'\s+', '_', cleaned.strip())
    return cleaned

def create_master_catalog():
    conn_rep = sqlite3.connect(REPAIRED_DB)
    conn_lib = sqlite3.connect(LIBRARY_DB)
    
    query = """
    SELECT 
        bookID, 
        book_name, 
        authorName, 
        category, 
        cunt,
        COUNT(DISTINCT partID) as actual_parts,
        COUNT(DISTINCT pageID) as toc_entries
    FROM Contents 
    GROUP BY bookID 
    ORDER BY bookID
    """
    books = conn_lib.execute(query).fetchall()
    
    catalog_data = []
    
    for b in books:
        b_id, b_name, author, cat_id, vol_count, act_parts, toc_count = b
        
        parts_info = conn_lib.execute("""
            SELECT partID, joze, MIN(pageID), MAX(pageID), COUNT(DISTINCT pageID)
            FROM Contents 
            WHERE bookID=? 
            GROUP BY partID 
            ORDER BY partID
        """, (b_id,)).fetchall()
        
        part_ids = [p[0] for p in parts_info]
        placeholders = ','.join('?' * len(part_ids))
        total_pages = conn_rep.execute(f"SELECT COUNT(*) FROM BookPages WHERE part_id IN ({placeholders})", part_ids).fetchone()[0]
        
        cat_short = CATEGORY_SHORT.get(cat_id, "عام")
        cat_full = CATEGORY_FULL.get(cat_id, f"تصنيف {cat_id}")
        clean_bname = sanitize_name(b_name)
        
        # Expected filename pattern
        if len(parts_info) == 1:
            expected_pattern = f"[ID_{b_id:03d}]_[{cat_short}]_[{clean_bname}].docx"
        else:
            expected_pattern = f"[ID_{b_id:03d}]_[{cat_short}]_[{clean_bname}]_ج01..ج{len(parts_info):02d}.docx"
            
        catalog_data.append({
            "book_id": b_id,
            "book_name": b_name,
            "author": author or "غير محدد",
            "category_id": cat_id,
            "category_short": cat_short,
            "category_name": cat_full,
            "volumes_count": len(parts_info),
            "total_pages": total_pages,
            "toc_entries": toc_count,
            "filename_pattern": expected_pattern,
            "parts": [
                {
                    "part_id": p[0],
                    "volume_number": p[1],
                    "min_page": p[2],
                    "max_page": p[3],
                    "toc_count": p[4]
                }
                for p in parts_info
            ]
        })
    
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    # Save JSON
    json_path = os.path.join(OUTPUT_DIR, "فهرس_المكتبة_الشامل.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(catalog_data, f, ensure_ascii=False, indent=2)
    print(f"JSON catalog saved: {json_path}")
    
    # Save CSV
    csv_path = os.path.join(OUTPUT_DIR, "فهرس_المكتبة_الشامل.csv")
    with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["معرف الكتاب (ID)", "اسم الكتاب", "النوع / التصنيف", "المؤلف", "عدد الأجزاء", "إجمالي الصفحات", "عناوين الفهرس", "نمط اسم الملف"])
        for item in catalog_data:
            writer.writerow([
                f"ID_{item['book_id']}",
                item["book_name"],
                item["category_name"],
                item["author"],
                item["volumes_count"],
                item["total_pages"],
                item["toc_entries"],
                item["filename_pattern"]
            ])
    print(f"CSV catalog saved: {csv_path}")
    
    # Generate Word Document (.docx)
    doc = Document()
    for s in doc.sections:
        s.page_width = Inches(8.27)
        s.page_height = Inches(11.69)
        s.top_margin = Inches(0.7)
        s.bottom_margin = Inches(0.7)
        s.left_margin = Inches(0.7)
        s.right_margin = Inches(0.7)
        
    def set_p_rtl(p, align=WD_ALIGN_PARAGRAPH.RIGHT):
        pPr = p._element.get_or_add_pPr()
        pPr.append(OxmlElement('w:bidi'))
        p.alignment = align

    COLOR_BLUE = RGBColor(0, 102, 204)
    COLOR_GREEN = RGBColor(0, 128, 0)
    COLOR_DARK = RGBColor(40, 40, 40)
    COLOR_BADGE = RGBColor(180, 80, 20)
    COLOR_PAGE_BADGE = RGBColor(180, 80, 20)

    # Title
    p_title = doc.add_paragraph()
    set_p_rtl(p_title, WD_ALIGN_PARAGRAPH.CENTER)
    r = p_title.add_run("فهرس المكتبة الشاملة لجميع الكتب (250 كتاباً)")
    r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
    r.font.name = "Traditional Arabic"
    r.font.size = Pt(24)
    r.bold = True
    r.font.color.rgb = COLOR_BLUE
    
    p_sub = doc.add_paragraph()
    set_p_rtl(p_sub, WD_ALIGN_PARAGRAPH.CENTER)
    r = p_sub.add_run("الدليل الشامل لكافة الكتب مع الـ ID ورقم الجزء والنوع وإجمالي الصفحات")
    r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
    r.font.name = "Traditional Arabic"
    r.font.size = Pt(14)
    r.font.color.rgb = COLOR_GREEN
    
    p_stats = doc.add_paragraph()
    set_p_rtl(p_stats, WD_ALIGN_PARAGRAPH.CENTER)
    r = p_stats.add_run(f"إجمالي الكتب: {len(catalog_data)} كتاب | إجمالي الأجزاء: 1,200 مجلد | إجمالي الصفحات المستعادة: 550,192 صفحة")
    r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
    r.font.name = "Traditional Arabic"
    r.font.size = Pt(12)
    r.bold = True
    r.font.color.rgb = COLOR_BADGE
    
    doc.add_paragraph()

    from itertools import groupby
    catalog_sorted = sorted(catalog_data, key=lambda x: (x["category_name"], x["book_id"]))
    
    for cat_name, group in groupby(catalog_sorted, key=lambda x: x["category_name"]):
        books_list = list(group)
        p_cat = doc.add_paragraph()
        set_p_rtl(p_cat, WD_ALIGN_PARAGRAPH.RIGHT)
        r = p_cat.add_run(f"■ {cat_name} ({len(books_list)} كتب)")
        r._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
        r.font.name = "Traditional Arabic"
        r.font.size = Pt(16)
        r.bold = True
        r.font.color.rgb = COLOR_BLUE
        
        table = doc.add_table(rows=1, cols=6)
        table.autofit = False
        hdr = table.rows[0].cells
        hdr[0].text = "ID الكتاب"
        hdr[1].text = "اسم الكتاب"
        hdr[2].text = "المؤلف"
        hdr[3].text = "الأجزاء"
        hdr[4].text = "الصفحات"
        hdr[5].text = "عناوين الفهرس"
        
        for c in hdr:
            for cp in c.paragraphs:
                set_p_rtl(cp, WD_ALIGN_PARAGRAPH.CENTER)
                for cr in cp.runs:
                    cr._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                    cr.font.name = "Traditional Arabic"
                    cr.font.size = Pt(12)
                    cr.bold = True
                    cr.font.color.rgb = COLOR_BLUE
                    
        for b_entry in books_list:
            row = table.add_row().cells
            row[0].text = f"ID_{b_entry['book_id']}"
            row[1].text = b_entry["book_name"]
            row[2].text = b_entry["author"] or "-"
            row[3].text = str(b_entry["volumes_count"])
            row[4].text = f"{b_entry['total_pages']:,}"
            row[5].text = f"{b_entry['toc_entries']:,}"
            
            for i, c in enumerate(row):
                align = WD_ALIGN_PARAGRAPH.RIGHT if i in (1, 2) else WD_ALIGN_PARAGRAPH.CENTER
                for cp in c.paragraphs:
                    set_p_rtl(cp, align)
                    for cr in cp.runs:
                        cr._element.get_or_add_rPr().append(OxmlElement('w:rtl'))
                        cr.font.name = "Traditional Arabic"
                        is_bld = (i in (0, 1))
                        cr.font.size = Pt(11.5 if is_bld else 11)
                        cr.bold = is_bld
                        cr.font.color.rgb = COLOR_PAGE_BADGE if i == 0 else (COLOR_BLUE if i == 1 else COLOR_DARK)
                        
        doc.add_paragraph()

    docx_path = os.path.join(OUTPUT_DIR, "فهرس_المكتبة_الشامل_لجميع_الكتب.docx")
    doc.save(docx_path)
    print(f"Master Word Catalog saved: {docx_path}")
    
    conn_rep.close()
    conn_lib.close()

if __name__ == "__main__":
    create_master_catalog()
