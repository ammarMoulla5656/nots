# -*- coding: utf-8 -*-
import sqlite3
import os
import json
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

BASE_DIR = r"d:\01_Projects\mobile\nots"
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
EXCEL_PATH = os.path.join(BASE_DIR, "تقرير_مطابقة_كتب_PDF_الشامل.xlsx")
EXCEL_FALLBACK_PATH = os.path.join(BASE_DIR, "تقرير_مطابقة_كتب_PDF_الشامل_محدث.xlsx")
EXCEL_FINAL_PATH = os.path.join(BASE_DIR, "ملف_روابط_PDF_النهائي_المعتمد_الشامل.xlsx")

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

def generate_excel_catalog(matching_data=None):
    if matching_data is None:
        if os.path.exists(MATCHING_DB):
            with open(MATCHING_DB, "r", encoding="utf-8") as f:
                matching_data = json.load(f)
        else:
            matching_data = {}

    conn_rep = sqlite3.connect(REPAIRED_DB)
    conn_lib = sqlite3.connect(LIBRARY_DB)

    query = """
    SELECT 
        bookID, 
        book_name, 
        authorName, 
        category, 
        cunt
    FROM Contents 
    GROUP BY bookID 
    ORDER BY bookID
    """
    books = conn_lib.execute(query).fetchall()

    wb = openpyxl.Workbook()
    ws_all = wb.active
    ws_all.title = "كافة المجلدات (1200 مجلد)"
    ws_all.views.sheetView[0].rightToLeft = True

    ws_under90 = wb.create_sheet(title="تحت 90% للمراجعة والتحقق")
    ws_under90.views.sheetView[0].rightToLeft = True

    ws_books = wb.create_sheet(title="ملخص الكتب (250 كتاباً)")
    ws_books.views.sheetView[0].rightToLeft = True

    # Styling
    header_fill = PatternFill(start_color="1B365D", end_color="1B365D", fill_type="solid")
    header_font = Font(name="Traditional Arabic", size=13, bold=True, color="FFFFFF")
    data_font = Font(name="Traditional Arabic", size=12)
    bold_data_font = Font(name="Traditional Arabic", size=12, bold=True)
    link_font = Font(name="Calibri", size=10, underline="single", color="0563C1")
    center_align = Alignment(horizontal="center", vertical="center")
    right_align = Alignment(horizontal="right", vertical="center")

    border_side = Side(border_style="thin", color="CCCCCC")
    thin_border = Border(left=border_side, right=border_side, top=border_side, bottom=border_side)

    headers = [
        "معرف الكتاب (ID)",
        "معرف الجزء (partID)",
        "اسم الكتاب في المصدر",
        "المؤلف",
        "التصنيف والنوع",
        "رقم الجزء / المجلد",
        "صفحات المصدر (DB)",
        "صفحات PDF و DOCX المتطابقة",
        "حالة التطابق والدرجة",
        "نسبة التطابق (%)",
        "مقدار الإزاحة (Offset)",
        "مصدر الـ PDF الأساسي",
        "أفضل رابط PDF مطابق (تنزيل مباشر)",
        "رابط PDF بديل (مكتبة أهل البيت)",
        "رابط مساحة حرة (Masaha)",
        "رابط التصفح (أهل البيت / الفكر)",
        "ملف الـ DOCX المحلي (فتح مباشر)",
        "ملف الـ PDF المحلي (فتح مباشر)",
        "ملاحظات الفحص والمطابقة"
    ]

    for sheet in (ws_all, ws_under90):
        sheet.append(headers)
        for col_idx in range(1, len(headers) + 1):
            cell = sheet.cell(row=1, column=col_idx)
            cell.fill = header_fill
            cell.font = header_font
            cell.alignment = center_align

    book_headers = [
        "معرف الكتاب (ID)",
        "اسم الكتاب في المصدر",
        "المؤلف",
        "التصنيف والنوع",
        "عدد الأجزاء / المجلدات",
        "إجمالي صفحات الكتاب",
        "تقييم التطابق",
        "متوسط نسبة التطابق (%)",
        "مصدر الـ PDF المعتمد",
        "أفضل رابط PDF مباشر (الجزء 1 / الكتاب)",
        "رابط التصفح في مكتبة أهل البيت / الفكر"
    ]
    ws_books.append(book_headers)
    for col_idx in range(1, len(book_headers) + 1):
        cell = ws_books.cell(row=1, column=col_idx)
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = center_align

    def style_part_row(sheet, r_idx, row_vals, sc_val, is_rejected):
        for col_idx in range(1, len(row_vals) + 1):
            c = sheet.cell(row=r_idx, column=col_idx)
            c.font = bold_data_font if col_idx in (1, 3, 8, 10) else data_font
            c.border = thin_border
            c.alignment = right_align if col_idx in (3, 4, 19) else center_align

            val_str = str(c.value or "")
            if col_idx in (13, 14, 15, 16) and val_str.startswith("http"):
                c.hyperlink = val_str
                c.font = link_font
            elif col_idx in (17, 18) and val_str and os.path.exists(val_str):
                c.hyperlink = val_str
                c.font = link_font

            if col_idx in (9, 10):
                if is_rejected:
                    c.fill = PatternFill(start_color="F8D7DA", end_color="F8D7DA", fill_type="solid")
                    c.font = Font(name="Traditional Arabic", size=12, bold=True, color="721C24")
                elif sc_val >= 90.0:
                    c.fill = PatternFill(start_color="D4EDDA", end_color="D4EDDA", fill_type="solid")
                    c.font = Font(name="Traditional Arabic", size=12, bold=True, color="155724")
                else:
                    c.fill = PatternFill(start_color="FFF3CD", end_color="FFF3CD", fill_type="solid")
                    c.font = Font(name="Traditional Arabic", size=12, bold=True, color="856404")

    row_all = 2
    row_u90 = 2
    book_row_num = 2

    for b in books:
        b_id, b_name, author, cat_id, cunt = b
        parts_rows = conn_lib.execute("""
            SELECT DISTINCT partID, joze 
            FROM Contents 
            WHERE bookID=? 
            ORDER BY partID
        """, (b_id,)).fetchall()

        total_vols = len(parts_rows)
        cat_name = CATEGORY_FULL.get(cat_id, "عام")

        book_total_pages = 0
        book_scores = []
        first_pdf_url = ""
        first_browse_url = ""
        first_source = ""

        for idx, (p_id, raw_joze) in enumerate(parts_rows, 1):
            pages_count = conn_rep.execute("SELECT COUNT(*) FROM BookPages WHERE part_id=?", (p_id,)).fetchone()[0]
            book_total_pages += pages_count

            if total_vols == 1:
                vol_label = "الكتاب كامل"
            elif str(raw_joze).isdigit():
                vol_label = f"الجزء {raw_joze}"
            elif str(raw_joze) == '-':
                vol_label = f"الجزء {idx}"
            else:
                vol_label = str(raw_joze)

            key = f"{b_id}_{p_id}"
            info = matching_data.get(key, {})

            masaha_url = info.get("masaha_url", f"https://www.masaha.org/book/{p_id}" if p_id < 7000 else "غير متوفر بمساحة حرة")
            has_masaha = info.get("has_masaha_pdf", False)

            ablibrary_url = info.get("ablibrary_url", f"https://ablibrary.net/search?q={b_name}")
            pdf_download = info.get("pdf_url", "")
            ab_pdf_url = info.get("ab_pdf_url", "")
            if not ab_pdf_url and pdf_download.endswith(".pdf") and "ablibrary.net" in pdf_download:
                ab_pdf_url = pdf_download

            pdf_source = info.get("pdf_source") or ("مساحة حرة" if has_masaha else ("مكتبة أهل البيت" if ab_pdf_url else "مكتبة أهل البيت / الفكر"))
            raw_status = info.get("status", "مطابق")
            offset = info.get("offset", 0)
            score_str = str(info.get("score", "0.0"))
            try:
                sc_val = float(score_str)
            except Exception:
                sc_val = 0.0
            book_scores.append(sc_val)
            score_display = f"{sc_val:.1f}%"

            is_rejected = "غير مطابق" in raw_status or "مرفوض" in raw_status
            if is_rejected:
                status_label = "❌ مرفوض (يحتاج رابط بديل)"
            elif info.get("downloaded"):
                status_label = "📥 معتمد وتم التنزيل بالجهاز"
            elif sc_val >= 90.0:
                status_label = "✔️ مطابق ممتاز (فوق 90%)"
            else:
                status_label = "⚠️ تحت 90% (للمراجعة والتحقق)"

            docx_path = info.get("docx_path", "")
            dl_status = info.get("local_pdf_path") if info.get("downloaded") else "جاهز للتنزيل عبر الأداة"
            synced_pages = info.get("synced_pages") or info.get("pdf_pages") or pages_count
            notes = info.get("notes", "")

            if not first_pdf_url and pdf_download:
                first_pdf_url = pdf_download
                first_browse_url = ablibrary_url
                first_source = pdf_source

            row = [
                f"ID_{b_id}",
                p_id,
                b_name,
                author or "غير محدد",
                cat_name,
                vol_label,
                pages_count,
                synced_pages,
                status_label,
                score_display,
                offset,
                pdf_source,
                pdf_download,
                ab_pdf_url or "—",
                masaha_url,
                ablibrary_url,
                docx_path,
                dl_status,
                notes
            ]

            ws_all.append(row)
            style_part_row(ws_all, row_all, row, sc_val, is_rejected)
            row_all += 1

            if sc_val < 90.0 or is_rejected:
                ws_under90.append(row)
                style_part_row(ws_under90, row_u90, row, sc_val, is_rejected)
                row_u90 += 1

        avg_sc = round(sum(book_scores) / len(book_scores), 1) if book_scores else 0.0
        b_status = "✔️ فوق 90% (مطابق ممتاز)" if avg_sc >= 90.0 else "⚠️ تحت 90% (يحتاج تحقق)"
        b_row = [
            f"ID_{b_id}",
            b_name,
            author or "غير محدد",
            cat_name,
            total_vols,
            book_total_pages,
            b_status,
            f"{avg_sc:.1f}%",
            first_source or "مكتبة أهل البيت",
            first_pdf_url,
            first_browse_url
        ]
        ws_books.append(b_row)
        for col_idx in range(1, len(b_row) + 1):
            c = ws_books.cell(row=book_row_num, column=col_idx)
            c.font = bold_data_font if col_idx in (1, 2, 8) else data_font
            c.border = thin_border
            c.alignment = right_align if col_idx in (2, 3) else center_align
            val_str = str(c.value or "")
            if col_idx in (10, 11) and val_str.startswith("http"):
                c.hyperlink = val_str
                c.font = link_font
            if col_idx in (7, 8):
                if avg_sc >= 90.0:
                    c.fill = PatternFill(start_color="D4EDDA", end_color="D4EDDA", fill_type="solid")
                    c.font = Font(name="Traditional Arabic", size=12, bold=True, color="155724")
                else:
                    c.fill = PatternFill(start_color="FFF3CD", end_color="FFF3CD", fill_type="solid")
                    c.font = Font(name="Traditional Arabic", size=12, bold=True, color="856404")
        book_row_num += 1

    # Auto column widths for all sheets
    for sheet in (ws_all, ws_under90, ws_books):
        for col in sheet.columns:
            max_len = max(len(str(cell.value or '')) for cell in col)
            col_letter = get_column_letter(col[0].column)
            sheet.column_dimensions[col_letter].width = min(max(max_len + 3, 14), 52)

    saved_paths = []
    for p in (EXCEL_FINAL_PATH, EXCEL_PATH, EXCEL_FALLBACK_PATH):
        try:
            wb.save(p)
            saved_paths.append(p)
        except PermissionError:
            pass

    print(f"Generated Excel Catalog ({row_all - 2} total, {row_u90 - 2} under 90%) at: {saved_paths}")
    conn_rep.close()
    conn_lib.close()
    return saved_paths[0] if saved_paths else EXCEL_PATH

if __name__ == "__main__":
    generate_excel_catalog()
