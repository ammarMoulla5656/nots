import sqlite3

SOURCE_DB = r"d:\01_Projects\mobile\nots\alhikmeh.db"
PAGE_SIZE = 4096

def read_varint(data, offset):
    res = 0
    for i in range(9):
        b = data[offset + i]
        if i == 8:
            res = (res << 8) | b
            return res, offset + 9
        res = (res << 7) | (b & 0x7f)
        if (b & 0x80) == 0:
            return res, offset + i + 1

# Let's search page 1 (or sqlite_master pages) to find the table definitions (CREATE TABLE)!
with open(SOURCE_DB, "rb") as f:
    for page_num in range(1, 100):
        f.seek(page_num * PAGE_SIZE)
        page = f.read(PAGE_SIZE)
        if b"CREATE TABLE" in page:
            print(f"Found 'CREATE TABLE' in page {page_num}:")
            # print all occurrences
            idx = 0
            while True:
                idx = page.find(b"CREATE TABLE", idx)
                if idx == -1:
                    break
                print(page[idx : idx + 300])
                idx += 12

