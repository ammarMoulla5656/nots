# -*- coding: utf-8 -*-
"""
=============================================================================
مستعرض وباحث محتويات قاعدة بيانات الحكمة (alhikmeh_repaired.db)
=============================================================================
الوظيفة:
  - البحث الفوري في نصوص آلاف صفحات الكتب الإسلامية.
  - البحث في المعجم اللغوي (القاموس المحيط ومعاني الكلمات).
  - استعراض صفحات أي كتاب برقم الكتاب ورقم الجزء والصفحة.
=============================================================================
"""

import os
import sys
import sqlite3

DB_PATH = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"

def search_dictionary(query, limit=10):
    if not os.path.exists(DB_PATH):
        print("❌ لم يتم العثور على قاعدة البيانات المستصلحة بعد. يرجى تشغيل أداة الإصلاح أولاً.")
        return

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.execute("SELECT word, meaning, content FROM MeaningLang WHERE word LIKE ? OR content LIKE ? LIMIT ?",
                (f"%{query}%", f"%{query}%", limit))
    rows = cur.fetchall()
    conn.close()

    print(f"\n🔍 نتائج البحث في المعجم اللغوي عن [{query}] ({len(rows)} نتائج):")
    print("-" * 65)
    for w, m, c in rows:
        print(f"📖 الكلمة / الجذر: {w}")
        print(f"   المعنى: {m}")
        if c and c != m:
            print(f"   الشواهد: {c[:120]}...")
        print("-" * 65)

def search_books_text(query, limit=5):
    if not os.path.exists(DB_PATH):
        print("❌ لم يتم العثور على قاعدة البيانات المستصلحة بعد.")
        return

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.execute("SELECT book_id, part_id, page_id, text FROM BookPages WHERE text LIKE ? LIMIT ?",
                (f"%{query}%", limit))
    rows = cur.fetchall()
    conn.close()

    print(f"\n🔍 نتائج البحث في نصوص الكتب عن [{query}] ({len(rows)} نتائج):")
    print("=" * 70)
    for b_id, p_id, page_no, txt in rows:
        print(f"📚 كتاب رقم: {b_id} | جزء: {p_id} | صفحة: {page_no}")
        print("-" * 70)
        # highlight snippet
        lines = [line.strip() for line in txt.split("\n") if query in line]
        if lines:
            print("النص المطابق:")
            for l in lines[:3]:
                print(f"  « {l} »")
        else:
            print(txt[:300] + "...")
        print("=" * 70)

def show_statistics():
    if not os.path.exists(DB_PATH):
        print("❌ لم يتم العثور على قاعدة البيانات المستصلحة بعد.")
        return

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.execute("SELECT count(*) FROM BookPages")
    book_pages = cur.fetchone()[0]
    cur.execute("SELECT count(DISTINCT book_id) FROM BookPages")
    books_count = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM MeaningLang")
    dict_count = cur.fetchone()[0]
    conn.close()

    print("\n" + "=" * 60)
    print(" 📊 إحصائيات محتوى قاعدة بيانات الحكمة المستعادة")
    print("=" * 60)
    print(f"📚 إجمالي الكتب المستقلة: {books_count:,} كتاب")
    print(f"📄 إجمالي صفحات الكتب: {book_pages:,} صفحة نصية كاملة")
    print(f"📖 إجمالي مدخلات المعجم اللغوي: {dict_count:,} كلمة ومادة لغوية")
    print("=" * 60)

def read_page(book_id, page_id, part_id=None):
    if not os.path.exists(DB_PATH):
        print("❌ لم يتم العثور على قاعدة البيانات المستصلحة بعد.")
        return

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    if part_id is not None:
        cur.execute("SELECT text FROM BookPages WHERE book_id=? AND part_id=? AND page_id=?", (book_id, part_id, page_id))
    else:
        cur.execute("SELECT text, part_id FROM BookPages WHERE book_id=? AND page_id=?", (book_id, page_id))
    row = cur.fetchone()
    conn.close()

    if not row:
        print(f"❌ لم يتم العثور على صفحة برقم {page_id} في كتاب {book_id}")
        return

    txt = row[0]
    p_info = part_id if part_id is not None else row[1]
    print("\n" + "=" * 70)
    print(f"📖 كتاب رقم: {book_id} | جزء: {p_info} | صفحة: {page_id}")
    print("=" * 70)
    print(txt)
    print("=" * 70)

def main():
    if not os.path.exists(DB_PATH):
        print(f"❌ ملف قاعدة البيانات المستصلحة غير موجود: {DB_PATH}")
        print("يرجى تشغيل أداة الإصلاح أولاً: python repair_alhikmeh_db.py")
        return

    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "--stats":
            show_statistics()
        elif cmd == "--dict" and len(sys.argv) > 2:
            search_dictionary(" ".join(sys.argv[2:]))
        elif cmd == "--search" and len(sys.argv) > 2:
            search_books_text(" ".join(sys.argv[2:]))
        elif cmd == "--read" and len(sys.argv) >= 4:
            read_page(int(sys.argv[2]), int(sys.argv[3]))
        return

    # وضع القائمة التفاعلية
    while True:
        print("\n" + "=" * 60)
        print(" 🔍 مستعرض وباحث قاعدة بيانات الحكمة المستعادة")
        print("=" * 60)
        print("1. إحصائيات عامة عن محتوى القاعدة")
        print("2. بحث في المعجم اللغوي (معاني الكلمات)")
        print("3. بحث في نصوص وصفحات الكتب")
        print("4. قراءة صفحة محددة (برقم الكتاب ورقم الصفحة)")
        print("5. خروج")
        print("-" * 60)
        choice = input("اختر رقم العملية (1-5): ").strip()
        if choice == "1":
            show_statistics()
        elif choice == "2":
            q = input("أدخل الكلمة أو الجذر للبحث: ").strip()
            if q:
                search_dictionary(q)
        elif choice == "3":
            q = input("أدخل جملة أو نص للبحث في الكتب: ").strip()
            if q:
                search_books_text(q)
        elif choice == "4":
            b = input("رقم الكتاب (Book ID): ").strip()
            p = input("رقم الصفحة (Page ID): ").strip()
            if b.isdigit() and p.isdigit():
                read_page(int(b), int(p))
        elif choice == "5":
            break

if __name__ == "__main__":
    main()
