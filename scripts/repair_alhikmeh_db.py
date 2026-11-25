import os
import sys
import sqlite3
import time

SOURCE_DB = r"d:\01_Projects\mobile\nots\alhikmeh.db"
TARGET_DB = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"
PAGE_SIZE = 4096
BATCH_SIZE = 50000

def read_varint(data, offset):
    res = 0
    for i in range(9):
        if offset + i >= len(data):
            return 0, len(data)
        b = data[offset + i]
        if i == 8:
            res = (res << 8) | b
            return res, offset + 9
        res = (res << 7) | (b & 0x7f)
        if (b & 0x80) == 0:
            return res, offset + i + 1
    return res, offset + 9

def repair_database():
    print("=" * 70)
    print(" 🛠️  بدء الإصلاح الدقيق والشامل لقاعدة بيانات الحكمة (alhikmeh.db)")
    print("=" * 70)

    src_size = os.path.getsize(SOURCE_DB)
    total_pages = src_size // PAGE_SIZE

    if os.path.exists(TARGET_DB):
        try:
            os.remove(TARGET_DB)
        except Exception:
            pass

    out_conn = sqlite3.connect(TARGET_DB)
    out_cur = out_conn.cursor()
    out_cur.execute("PRAGMA synchronous = OFF")
    out_cur.execute("PRAGMA journal_mode = MEMORY")
    out_cur.execute("PRAGMA cache_size = 100000")

    out_cur.execute("""
    CREATE TABLE Books (
        id INTEGER PRIMARY KEY,
        book_name TEXT,
        authorName TEXT,
        category INTEGER,
        parts_count INTEGER
    )
    """)

    out_cur.execute("""
    CREATE TABLE BookPages (
        id INTEGER PRIMARY KEY,
        part_id INTEGER,
        page_id INTEGER,
        text TEXT
    )
    """)

    out_cur.execute("""
    CREATE TABLE MeaningLang (
        id INTEGER PRIMARY KEY,
        word TEXT,
        meaning TEXT,
        content TEXT
    )
    """)
    out_conn.commit()

    start_time = time.time()
    books_batch = []
    pages_batch = []
    dict_batch = []

    total_books = 0
    total_pages_count = 0
    total_dict = 0

    buffer_pages = 4096 # 16 MB
    pages_processed = 0

    with open(SOURCE_DB, "rb") as f:
        while pages_processed < total_pages:
            pages_to_read = min(buffer_pages, total_pages - pages_processed)
            block = f.read(pages_to_read * PAGE_SIZE)
            if not block:
                break

            for i in range(pages_to_read):
                p_off = i * PAGE_SIZE
                page = block[p_off : p_off + PAGE_SIZE]
                if not page or page[0] != 0x0d:
                    continue

                num_cells = int.from_bytes(page[3:5], "big")
                if num_cells == 0 or num_cells > 500:
                    continue

                for ci in range(num_cells):
                    ptr_off = 8 + 2 * ci
                    ptr = int.from_bytes(page[ptr_off : ptr_off + 2], "big")
                    if ptr >= PAGE_SIZE:
                        continue

                    try:
                        payload_len, off = read_varint(page, ptr)
                        rowid, off = read_varint(page, off)
                        hdr_len, val_off = read_varint(page, off)
                        hdr_end = off + hdr_len
                        sts = []
                        cur = val_off
                        while cur < hdr_end and cur < len(page):
                            st, cur = read_varint(page, cur)
                            sts.append(st)

                        val_cur = hdr_end
                        cols = []
                        for st in sts:
                            if st == 0:
                                cols.append(None)
                            elif st == 1:
                                cols.append(int.from_bytes(page[val_cur:val_cur+1], "big", signed=True))
                                val_cur += 1
                            elif st == 2:
                                cols.append(int.from_bytes(page[val_cur:val_cur+2], "big", signed=True))
                                val_cur += 2
                            elif st == 3:
                                cols.append(int.from_bytes(page[val_cur:val_cur+3], "big", signed=True))
                                val_cur += 3
                            elif st == 4:
                                cols.append(int.from_bytes(page[val_cur:val_cur+4], "big", signed=True))
                                val_cur += 4
                            elif st == 5:
                                cols.append(int.from_bytes(page[val_cur:val_cur+6], "big", signed=True))
                                val_cur += 6
                            elif st == 6:
                                cols.append(int.from_bytes(page[val_cur:val_cur+8], "big", signed=True))
                                val_cur += 8
                            elif st == 7:
                                val_cur += 8
                                cols.append(0.0)
                            elif st == 8:
                                cols.append(0)
                            elif st == 9:
                                cols.append(1)
                            elif st >= 12 and st % 2 == 0:
                                blen = (st - 12) // 2
                                val_cur += blen
                                cols.append(None)
                            elif st >= 13 and st % 2 == 1:
                                tlen = (st - 13) // 2
                                txt = page[val_cur : val_cur + tlen].decode("utf-8", errors="ignore")
                                cols.append(txt)
                                val_cur += tlen
                            else:
                                cols.append(None)

                        if len(cols) == 5:
                            # Check if this is Books table: cols[1] is book_name string
                            if isinstance(cols[1], str) and isinstance(cols[2], str):
                                books_batch.append((rowid, cols[1], cols[2], cols[3], cols[4]))
                            else:
                                # cols = [id_null, part_id, page_no_prev, page_no, text]
                                part_id = cols[1]
                                page_no = cols[3]
                                text_content = cols[4]
                                pages_batch.append((rowid, part_id, page_no, text_content))

                        elif len(cols) == 4:
                            # MeaningLang: [id, word, meaning, content]
                            dict_batch.append((rowid, cols[1], cols[2], cols[3]))

                    except Exception:
                        pass

            pages_processed += pages_to_read

            if len(pages_batch) >= BATCH_SIZE:
                out_cur.executemany("INSERT OR IGNORE INTO BookPages VALUES (?, ?, ?, ?)", pages_batch)
                total_pages_count += len(pages_batch)
                pages_batch = []
                out_conn.commit()

            if len(dict_batch) >= BATCH_SIZE:
                out_cur.executemany("INSERT OR IGNORE INTO MeaningLang VALUES (?, ?, ?, ?)", dict_batch)
                total_dict += len(dict_batch)
                dict_batch = []
                out_conn.commit()

            pct = (pages_processed / total_pages) * 100
            sys.stdout.write(f"\r⏳ التقدم: {pct:.1f}% | صفحات الكتب: {total_pages_count + len(pages_batch):,} | الكتب: {total_books + len(books_batch):,}")
            sys.stdout.flush()

    if pages_batch:
        out_cur.executemany("INSERT OR IGNORE INTO BookPages VALUES (?, ?, ?, ?)", pages_batch)
        total_pages_count += len(pages_batch)
    if books_batch:
        out_cur.executemany("INSERT OR IGNORE INTO Books VALUES (?, ?, ?, ?, ?)", books_batch)
        total_books += len(books_batch)
    if dict_batch:
        out_cur.executemany("INSERT OR IGNORE INTO MeaningLang VALUES (?, ?, ?, ?)", dict_batch)
        total_dict += len(dict_batch)

    out_conn.commit()

    print("\n\n⚡ جاري إنشاء الفهارس السريعة (Indexing)...")
    out_cur.execute("CREATE INDEX IF NOT EXISTS idx_bp_part_page ON BookPages(part_id, page_id)")
    out_cur.execute("CREATE INDEX IF NOT EXISTS idx_dict_word ON MeaningLang(word)")
    out_conn.commit()
    out_conn.close()

    elapsed = time.time() - start_time
    print(f"\n🎉 تم الانتهاء بنجاح في {elapsed:.1f} ثانية!")
    print(f"📚 إجمالي الكتب: {total_books:,}")
    print(f"📖 إجمالي الصفحات المستعادة: {total_pages_count:,}")
    print(f"🔤 إجمالي المعجم: {total_dict:,}")

if __name__ == "__main__":
    repair_database()
