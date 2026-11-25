# -*- coding: utf-8 -*-
"""
=============================================================================
أداة تحميل كتب موقع جامع الكتب الإسلامية (ketabonline.com) وتحويلها إلى Word (DOCX)
=============================================================================
المؤلف: Antigravity AI Assistant
الوظيفة:
  - استخراج وتحليل رابط الكتاب وفهم أجزائه تلقائياً.
  - تحميل جميع الأجزاء (أو أجزاء محددة) بأقصى سرعة عبر التنزيل المتوازي (Multi-threading).
  - ميزة الاستئناف والتخزين المؤقت (Cache) لضمان عدم ضياع أي صفحة في حال انقطاع الاتصال.
  - تنظيف النصوص من أي عناصر ويب غير مرغوبة (أزرار النسخ، المشاركة، الأيقونات).
  - تنسيق كل جزء في ملف Word DOCX احترافي مع دعم كامل للاتجاه من اليمين لليسار (RTL)
    والعناوين والآيات والشواهد وهوامش الصفحات وأرقامها المطابقة للمطبوع.
=============================================================================
"""

import os
import sys
import re
import json
import time
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed

# التحقق من تثبيت المكتبات المطلوبة وتثبيتها تلقائياً إن لزم
try:
    import requests
except ImportError:
    print("جاري تثبيت مكتبة requests...")
    os.system(f'"{sys.executable}" -m pip install requests')
    import requests

try:
    from bs4 import BeautifulSoup, NavigableString, Tag
except ImportError:
    print("جاري تثبيت مكتبة beautifulsoup4...")
    os.system(f'"{sys.executable}" -m pip install beautifulsoup4')
    from bs4 import BeautifulSoup, NavigableString, Tag

try:
    import docx
    from docx.shared import Pt, Inches, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import parse_xml
    from docx.oxml.ns import nsdecls
except ImportError:
    print("جاري تثبيت مكتبة python-docx...")
    os.system(f'"{sys.executable}" -m pip install python-docx')
    import docx
    from docx.shared import Pt, Inches, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import parse_xml
    from docx.oxml.ns import nsdecls


# =============================================================================
# إعدادات وثوابت واجهة برمجة تطبيقات الموقع (KetabOnline API)
# =============================================================================
DEFAULT_URL = "https://ketabonline.com/ar/books/2119/read?part=1&page=1"
API_BASE = "https://backend.ketabonline.com/api/v2"
API_KEY = "chf3T5y9o1YXftncU5pd45QZx9NjkJg"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "API-KEY": API_KEY,
    "Api-Lang": "ar",
    "Accept": "application/json",
}

# =============================================================================
# دوال التنسيق الداعمة للغة العربية في Microsoft Word (RTL & XML)
# =============================================================================
def set_rtl_paragraph(p):
    """ضبط اتجاه الفقرة من اليمين إلى اليسار مع المحاذاة لليمين"""
    p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    pPr = p._p.get_or_add_pPr()
    pPr.append(parse_xml(r'<w:bidi %s w:val="1"/>' % nsdecls('w')))

def add_rtl_run(p, text, font_name="Traditional Arabic", size=14, bold=False, italic=False, color=None, superscript=False):
    """إضافة مقطع نصي عربي مع خصائص الخط والاتجاه"""
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

def sanitize_filename(name):
    """تنظيف اسم الملف من الحروف غير الصالحة في نظام التشغيل"""
    return re.sub(r'[\\/*?:"<>|]', '_', name).strip()

def extract_book_id(url_or_id):
    """استخراج معرّف الكتاب من الرابط أو الرقم المدخل"""
    url_or_id = url_or_id.strip()
    if url_or_id.isdigit():
        return int(url_or_id)
    match = re.search(r'/books/(\d+)', url_or_id)
    if match:
        return int(match.group(1))
    # محاولة استخراج أول رقم موجود
    digits = re.findall(r'\d+', url_or_id)
    if digits:
        return int(digits[0])
    raise ValueError(f"تعذر استخراج رقم الكتاب من: {url_or_id}")

# =============================================================================
# دوال التنزيل وجلب البيانات من الموقع
# =============================================================================
def fetch_book_metadata(session, book_id):
    """جلب بيانات الكتاب وفهرسه وأجزائه"""
    url = f"{API_BASE}/books/{book_id}"
    resp = session.get(url, headers=HEADERS, timeout=20)
    resp.raise_for_status()
    data = resp.json().get("data", {})
    return data

def fetch_pages_list(session, book_id):
    """جلب قائمة الصفحات الكاملة الخاصة بالكتاب"""
    url = f"{API_BASE}/books/{book_id}/pages_list"
    resp = session.get(url, headers=HEADERS, timeout=25)
    resp.raise_for_status()
    data = resp.json().get("data", [])
    return data

def fetch_single_page(session, book_id, page_id, cache_dir=None, retries=3):
    """تحميل محتوى صفحة واحدة مع دعم التخزين المؤقت وإعادة المحاولة"""
    if cache_dir:
        cache_file = os.path.join(cache_dir, f"page_{page_id}.json")
        if os.path.exists(cache_file):
            try:
                with open(cache_file, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass

    url = f"{API_BASE}/books/{book_id}/pages/{page_id}"
    for attempt in range(retries):
        try:
            resp = session.get(url, headers=HEADERS, timeout=20)
            if resp.status_code == 200:
                data = resp.json()
                if cache_dir:
                    cache_file = os.path.join(cache_dir, f"page_{page_id}.json")
                    with open(cache_file, "w", encoding="utf-8") as f:
                        json.dump(data, f, ensure_ascii=False)
                return data
            elif resp.status_code == 404:
                return None
        except Exception as e:
            if attempt == retries - 1:
                print(f"\n[تحذير] فشل تحميل الصفحة {page_id}: {e}")
                return None
            time.sleep(1 + attempt)
    return None

# =============================================================================
# دوال تحويل محتوى HTML إلى مستند DOCX
# =============================================================================
def extract_text_runs(tag, current_style=None):
    """استخراج المقاطع النصية وتنسيقاتها من عناصر الفقرة بتكرار منظم"""
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
            
            # تجاهل أزرار النسخ والروابط الزائدة
            if "g-copy" in classes or child.name == "i":
                continue
                
            if "g-footnote-link" in classes:
                new_style["footnote"] = True
                new_style["superscript"] = True
                new_style["bold"] = True
                new_style["color"] = RGBColor(0, 102, 204)
                new_style["size"] = 10
            elif "g-footnote-target" in classes:
                new_style["bold"] = True
                new_style["color"] = RGBColor(0, 102, 204)
            elif "g-aya" in classes:
                new_style["bold"] = True
                new_style["color"] = RGBColor(0, 128, 0) # لون أخضر للآيات القرآنية
            elif "g-quotes" in classes:
                new_style["italic"] = True
                
            runs.extend(extract_text_runs(child, new_style))
    return runs

def add_page_to_docx(doc, page_data, part_name):
    """إضافة صفحة كاملة بهوامشها وعناوينها إلى ملف Word"""
    if not page_data or "content" not in page_data:
        return

    page_num = page_data.get("page", "")
    html_content = page_data.get("content", "")
    soup = BeautifulSoup(html_content, "html.parser")

    # حذف الأيقونات وأزرار النسخ التابعة لواجهة الويب
    for el in soup.find_all(class_="g-copy"):
        el.decompose()
    for el in soup.find_all("i", class_="ico-files"):
        el.decompose()

    # فصل قسم حواشي الصفحة (الهوامش السفلية)
    footer_div = soup.find("div", class_="g-page-footer")
    if footer_div:
        footer_soup = footer_div.extract()
    else:
        footer_soup = None

    # إضافة رأس الصفحة (فاصل رقم الصفحة المطبوعة)
    p_hdr = doc.add_paragraph()
    set_rtl_paragraph(p_hdr)
    p_hdr.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_hdr.paragraph_format.space_before = Pt(14)
    p_hdr.paragraph_format.space_after = Pt(4)
    header_label = f"--- [ الجزء: {part_name} | الصفحة: {page_num} ] ---"
    add_rtl_run(p_hdr, header_label, font_name="Traditional Arabic", size=11, bold=True, color=RGBColor(120, 120, 120))

    # معالجة عناصر صلب الصفحة
    for el in soup.children:
        if not isinstance(el, Tag):
            continue

        classes = el.get("class", [])

        # العناوين الرئيسية والفرعية
        if "g-title" in classes or el.name in ["h1", "h2", "h3", "h4"]:
            title_text = el.get_text().strip()
            if title_text:
                p_title = doc.add_paragraph()
                set_rtl_paragraph(p_title)
                p_title.paragraph_format.space_before = Pt(10)
                p_title.paragraph_format.space_after = Pt(4)
                add_rtl_run(p_title, title_text, font_name="Traditional Arabic", size=16, bold=True, color=RGBColor(150, 20, 20))
            continue

        # الفقرات العادية والشواهد
        if "g-paragraph" in classes or el.name == "p":
            runs = extract_text_runs(el)
            if not runs:
                continue

            p_body = doc.add_paragraph()
            set_rtl_paragraph(p_body)
            p_body.paragraph_format.space_before = Pt(2)
            p_body.paragraph_format.space_after = Pt(4)
            p_body.paragraph_format.line_spacing = 1.25

            for text, style in runs:
                add_rtl_run(
                    p_body,
                    text,
                    font_name="Traditional Arabic",
                    size=style.get("size", 14),
                    bold=style.get("bold", False),
                    italic=style.get("italic", False),
                    color=style.get("color", None),
                    superscript=style.get("superscript", False)
                )

    # معالجة هوامش الصفحة السفلية إن وجدت
    if footer_soup:
        fn_paragraphs = footer_soup.find_all("p", class_="g-paragraph")
        if fn_paragraphs:
            # خط فاصل الهامش
            p_sep = doc.add_paragraph()
            set_rtl_paragraph(p_sep)
            p_sep.paragraph_format.space_before = Pt(8)
            p_sep.paragraph_format.space_after = Pt(2)
            add_rtl_run(p_sep, "____________________________________", font_name="Traditional Arabic", size=9, color=RGBColor(170, 170, 170))

            for fn_p in fn_paragraphs:
                fn_runs = extract_text_runs(fn_p)
                if not fn_runs:
                    continue

                p_fn = doc.add_paragraph()
                set_rtl_paragraph(p_fn)
                p_fn.paragraph_format.space_before = Pt(1)
                p_fn.paragraph_format.space_after = Pt(2)
                p_fn.paragraph_format.line_spacing = 1.15

                for text, style in fn_runs:
                    color = style.get("color") or RGBColor(60, 60, 60)
                    add_rtl_run(
                        p_fn,
                        text,
                        font_name="Traditional Arabic",
                        size=11,
                        bold=style.get("bold", False),
                        italic=style.get("italic", False),
                        color=color,
                        superscript=style.get("superscript", False)
                    )

def create_book_part_document(book_meta, part_name, pages_data, page_breaks=True):
    """إنشاء مستند Word للجزء المحدد وتنسيق صفحة الغلاف والصفحات مع فصل كل صفحة بفاصل صفحات"""
    doc = docx.Document()

    # ضبط هوامش الصفحة واتجاه المقطع RTL
    section = doc.sections[0]
    section.top_margin = Inches(1)
    section.bottom_margin = Inches(1)
    section.left_margin = Inches(1)
    section.right_margin = Inches(1)

    sectPr = section._sectPr
    sectPr.append(parse_xml(r'<w:bidi %s w:val="1"/>' % nsdecls('w')))

    # 1. صفحة الغلاف / العنوان
    p_title = doc.add_paragraph()
    set_rtl_paragraph(p_title)
    p_title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_title.paragraph_format.space_before = Pt(36)
    p_title.paragraph_format.space_after = Pt(12)
    book_title = book_meta.get("title", "الكتاب")
    add_rtl_run(p_title, book_title, font_name="Traditional Arabic", size=24, bold=True, color=RGBColor(24, 43, 73))

    # اسم الجزء
    p_part = doc.add_paragraph()
    set_rtl_paragraph(p_part)
    p_part.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_part.paragraph_format.space_before = Pt(6)
    p_part.paragraph_format.space_after = Pt(20)
    add_rtl_run(p_part, f"المجلد ({part_name})", font_name="Traditional Arabic", size=18, bold=True, color=RGBColor(140, 20, 20))

    # بيانات المؤلف والمحقق والناشر
    author = book_meta.get("author") or {}
    author_name = author.get("name") if isinstance(author, dict) else ""
    if not author_name and book_meta.get("authors"):
        author_name = ", ".join([a.get("name", "") for a in book_meta.get("authors", [])])

    reviewer = book_meta.get("reviewer", "")
    publisher = book_meta.get("publisher", "")
    year = book_meta.get("year", "")

    p_meta = doc.add_paragraph()
    set_rtl_paragraph(p_meta)
    p_meta.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_meta.paragraph_format.line_spacing = 1.3
    
    if author_name:
        add_rtl_run(p_meta, "المؤلف: ", size=14, bold=True)
        add_rtl_run(p_meta, f"{author_name}\n", size=14)
    if reviewer:
        add_rtl_run(p_meta, "تحقيق: ", size=13, bold=True)
        add_rtl_run(p_meta, f"{reviewer}\n", size=13)
    if publisher:
        add_rtl_run(p_meta, "الناشر: ", size=13, bold=True)
        add_rtl_run(p_meta, f"{publisher}\n", size=13)
    if year:
        add_rtl_run(p_meta, "سنة النشر: ", size=13, bold=True)
        add_rtl_run(p_meta, f"{year}\n", size=13)

    # فاصل صفحة بعد الغلاف
    doc.add_page_break()

    # 2. إضافة كافة الصفحات تباعاً مع فاصل صفحات حقيقي (Page Break) بين كل صفحة
    valid_pages = [p for p in pages_data if p]
    for idx, page_data in enumerate(valid_pages):
        # إضافة فاصل صفحات قبل كل صفحة جديدة (بعد الأولى)
        if idx > 0 and page_breaks:
            doc.add_page_break()
        add_page_to_docx(doc, page_data, part_name)

    return doc

# =============================================================================
# شريط التقدم المرئي البسيط في سطر الأوامر
# =============================================================================
def print_progress(current, total, prefix="التقدم", suffix="مكتمل", bar_length=30):
    percent = float(current) / max(total, 1)
    arrow = "█" * int(round(percent * bar_length))
    spaces = "-" * (bar_length - len(arrow))
    sys.stdout.write(f"\r{prefix} [{arrow}{spaces}] {current}/{total} ({percent*100:.1f}%) {suffix}")
    sys.stdout.flush()
    if current >= total:
        sys.stdout.write("\n")

# =============================================================================
# الدالة الرئيسية للتحميل والتشغيل
# =============================================================================
def run_downloader(url_or_id=None, selected_parts=None, output_dir=None, max_workers=12, page_breaks=True):
    if not url_or_id:
        url_or_id = DEFAULT_URL

    book_id = extract_book_id(url_or_id)

    print("=" * 70)
    print(" 📖 أداة تحميل كتب موقع جامع الكتب الإسلامية (ketabonline.com) إلى Word DOCX")
    print("=" * 70)
    print(f"🔗 معرّف الكتاب المستهدف: {book_id}")
    print(f"📄 فصل الصفحات (Page Breaks): {'مفعل (كل صفحة في صفحة منفصلة)' if page_breaks else 'معطل (نص متصل)'}")

    session = requests.Session()
    adapter = requests.adapters.HTTPAdapter(pool_connections=max_workers, pool_maxsize=max_workers)
    session.mount("https://", adapter)

    # 1. جلب بيانات الكتاب
    print("⏳ جلب بيانات وفهرس الكتاب من الموقع...")
    book_meta = fetch_book_metadata(session, book_id)
    book_title = book_meta.get("title", f"كتاب_{book_id}")
    author_info = book_meta.get("author") or {}
    author_name = author_info.get("name") if isinstance(author_info, dict) else ""
    if not author_name and book_meta.get("authors"):
        author_name = ", ".join([a.get("name", "") for a in book_meta.get("authors", [])])

    print(f"\n📘 عنوان الكتاب: {book_title}")
    if author_name:
        print(f"✍️  المؤلف: {author_name}")
    print(f"📚 إجمالي الأجزاء في الموقع: {len(book_meta.get('parts', []))}")

    # 2. جلب قائمة الصفحات الكاملة
    print("⏳ جلب خريطة الصفحات والأجزاء...")
    pages_list = fetch_pages_list(session, book_id)
    if not pages_list:
        print("❌ لم يتم العثور على صفحات لهذا الكتاب!")
        return

    # تقسيم الصفحات حسب الأجزاء
    parts_map = {}
    for item in pages_list:
        p_name = str(item.get("part", "1"))
        if p_name not in parts_map:
            parts_map[p_name] = []
        parts_map[p_name].append(item)

    print(f"\n📑 الأجزاء المتاحة وعدد صفحات كل جزء:")
    for p_name, p_items in sorted(parts_map.items(), key=lambda x: str(x[0])):
        print(f"   - الجزء {p_name}: {len(p_items)} صفحة")

    # تحديد الأجزاء المطلوبة للتنزيل
    if selected_parts:
        target_parts = [str(p) for p in selected_parts if str(p) in parts_map]
    else:
        target_parts = list(parts_map.keys())

    if not target_parts:
        print("❌ لم يتم العثور على الأجزاء المحددة للتنزيل.")
        return

    print(f"\n🎯 الأجزاء المستهدفة للتحويل إلى DOCX: {target_parts}")

    # إعداد مجلدات الحفظ والتخزين المؤقت
    if not output_dir:
        output_dir = os.path.join(os.getcwd(), "كتب_محملة_docx")
    os.makedirs(output_dir, exist_ok=True)

    cache_dir = os.path.join(os.getcwd(), ".cache_ketab", f"book_{book_id}")
    os.makedirs(cache_dir, exist_ok=True)

    total_start_time = time.time()
    generated_files = []

    # 3. معالجة كل جزء: تنزيل الصفحات بالتوازي ثم تجميع DOCX
    for p_name in target_parts:
        part_items = parts_map[p_name]
        total_part_pages = len(part_items)
        print("\n" + "-" * 70)
        print(f"🚀 بدء تحميل ومعالجة [ الجزء {p_name} ] ({total_part_pages} صفحة)...")

        # خريطة لحفظ الصفحات مع الحفاظ على الترتيب الأصلي
        downloaded_pages = {}
        completed_count = 0
        print_progress(0, total_part_pages, prefix=f" الجزء {p_name}")

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            future_to_item = {
                executor.submit(fetch_single_page, session, book_id, item["id"], cache_dir): item
                for item in part_items
            }

            for future in as_completed(future_to_item):
                item = future_to_item[future]
                try:
                    page_data = future.result()
                    downloaded_pages[item["id"]] = page_data
                except Exception as e:
                    print(f"\n[خطأ] فشل جلب الصفحة {item['id']}: {e}")
                completed_count += 1
                print_progress(completed_count, total_part_pages, prefix=f" الجزء {p_name}")

        # ترتيب الصفحات حسب الترتيب الصحيح للكتاب
        ordered_pages = [downloaded_pages.get(item["id"]) for item in part_items if item["id"] in downloaded_pages]

        print(f"📝 جاري إنشاء وتنسيق ملف Word DOCX للجزء {p_name} مع فصل الصفحات...")
        doc = create_book_part_document(book_meta, p_name, ordered_pages, page_breaks=page_breaks)

        # تسمية ملف الإخراج
        safe_title = sanitize_filename(book_title)
        out_filename = f"{safe_title} - الجزء {p_name}.docx"
        out_filepath = os.path.join(output_dir, out_filename)
        doc.save(out_filepath)

        file_size_mb = os.path.getsize(out_filepath) / (1024 * 1024)
        print(f"✅ تم حفظ الملف بنجاح: {out_filename} ({file_size_mb:.2f} ميجابايت)")
        generated_files.append(out_filepath)

    total_elapsed = time.time() - total_start_time
    print("\n" + "=" * 70)
    print(f"🎉 اكتمل تحميل وتحويل جميع الأجزاء المطلوبة في {total_elapsed:.1f} ثانية!")
    print(f"📂 مسار مجلد الحفظ:")
    print(f"   {os.path.abspath(output_dir)}")
    print("الملفات الناتجة:")
    for f in generated_files:
        print(f"   📄 {os.path.basename(f)}")
    print("=" * 70)

# =============================================================================
# نقطة الدخول عند التشغيل من سطر الأوامر أو النقر المزدوج
# =============================================================================
def main():
    parser = argparse.ArgumentParser(description="أداة تحميل كتب موقع جامع الكتب الإسلامية وتحويلها إلى Word DOCX")
    parser.add_argument("--url", "-u", default=None, help="رابط الكتاب أو معرّفه الرقمي (افتراضياً: كتاب 2119 المقاصد النحوية)")
    parser.add_argument("--parts", "-p", nargs="*", default=None, help="أرقام الأجزاء المراد تنزيلها (افتراضياً: تنزيل الـ 4 أجزاء كلها)")
    parser.add_argument("--output", "-o", default=None, help="مجلد حفظ الملفات الناتجة")
    parser.add_argument("--threads", "-t", type=int, default=12, help="عدد خيوط التنزيل المتوازي (افتراضياً 12)")
    parser.add_argument("--continuous", action="store_true", default=False, help="تعطيل فواصل الصفحات وجعل النص متصلاً (افتراضياً: الصفحات مفصولة)")

    args = parser.parse_args()

    # إذا تم التشغيل بدون وسائط من الطرفية، نفحص إذا كان المستخدم يريد إدخال رابط أو المتابعة مباشرة
    target_url = args.url
    if not target_url:
        print("=" * 70)
        print(" أداة تحميل الكتب وتحويلها إلى DOCX من موقع جامع الكتب الإسلامية")
        print("=" * 70)
        print(f"الرابط الافتراضي المستهدف:")
        print(f"👉 {DEFAULT_URL}")
        print("   (المقاصد النحوية في شرح شواهد شروح الألفية - 4 أجزاء كاملة)")
        print("-" * 70)
        
        # فحص إن كانت البيئة تفاعلية
        if sys.stdin.isatty():
            user_input = input("اضغط [Enter] لتحميل الأجزاء الأربعة مباشرة، أو الصق رابط كتاب آخر: ").strip()
            if user_input:
                target_url = user_input
            else:
                target_url = DEFAULT_URL
        else:
            target_url = DEFAULT_URL

    run_downloader(
        url_or_id=target_url,
        selected_parts=args.parts,
        output_dir=args.output,
        max_workers=args.threads,
        page_breaks=not args.continuous
    )

if __name__ == "__main__":
    main()
