import sqlite3
import os

lib_path = r"d:\01_Projects\mobile\nots\library.db"
rep_path = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"

print("--- Checking library.db ---")
conn_lib = sqlite3.connect(lib_path)
cur_lib = conn_lib.cursor()
tables_lib = cur_lib.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
print("Tables in library.db:", [t[0] for t in tables_lib])

for table in tables_lib:
    name = table[0]
    count = cur_lib.execute(f"SELECT COUNT(*) FROM `{name}`").fetchone()[0]
    cols = [c[1] for c in cur_lib.execute(f"PRAGMA table_info(`{name}`)").fetchall()]
    print(f"Table '{name}': {count} rows. Columns: {cols}")

print("\nSample from Contents in library.db:")
try:
    rows = cur_lib.execute("SELECT * FROM Contents LIMIT 3").fetchall()
    for r in rows:
        print(r)
except Exception as e:
    print("Error querying Contents:", e)

print("\n--- Checking distinct books in library.db Contents ---")
try:
    books_in_contents = cur_lib.execute("SELECT bookID, book_name, authorName, COUNT(*), MIN(partID), MAX(partID), MIN(pageID), MAX(pageID) FROM Contents GROUP BY bookID ORDER BY bookID").fetchall()
    print(f"Total distinct books in Contents: {len(books_in_contents)}")
    for b in books_in_contents[:10]:
        print(b)
except Exception as e:
    print("Error:", e)

conn_lib.close()

print("\n--- Checking alhikmeh_repaired.db ---")
conn_rep = sqlite3.connect(rep_path)
cur_rep = conn_rep.cursor()
tables_rep = cur_rep.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
print("Tables in alhikmeh_repaired.db:", [t[0] for t in tables_rep])

for table in tables_rep:
    name = table[0]
    count = cur_rep.execute(f"SELECT COUNT(*) FROM `{name}`").fetchone()[0]
    cols = [c[1] for c in cur_rep.execute(f"PRAGMA table_info(`{name}`)").fetchall()]
    print(f"Table '{name}': {count} rows. Columns: {cols}")

print("\nChecking distinct book_id in BookPages:")
book_counts = cur_rep.execute("SELECT book_id, COUNT(*), MIN(part_id), MAX(part_id), MIN(page_id), MAX(page_id) FROM BookPages GROUP BY book_id ORDER BY book_id").fetchall()
print(f"Total distinct books in BookPages: {len(book_counts)}")
for b in book_counts[:10]:
    print(b)

conn_rep.close()
