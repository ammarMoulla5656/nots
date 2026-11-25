import sqlite3

lib_path = r"d:\01_Projects\mobile\nots\library.db"
rep_path = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"

conn_lib = sqlite3.connect(lib_path)
conn_rep = sqlite3.connect(rep_path)

print("Checking BookPages sample:")
rows = conn_rep.execute("SELECT id, book_id, part_id, page_id, substr(text, 1, 100) FROM BookPages LIMIT 10").fetchall()
for r in rows:
    print(r)

print("\nChecking BookPages where book_id=1:")
rows = conn_rep.execute("SELECT id, book_id, part_id, page_id, substr(text, 1, 100) FROM BookPages WHERE book_id=1 LIMIT 5").fetchall()
print(f"Count for book_id=1: {len(rows)}")
for r in rows:
    print(r)

print("\nChecking BookPages min/max for different book_ids:")
rows = conn_rep.execute("SELECT book_id, count(*), min(part_id), max(part_id), min(page_id), max(page_id) FROM BookPages GROUP BY book_id ORDER BY count(*) DESC LIMIT 15").fetchall()
for r in rows:
    print(r)

print("\nWait, why did BookPages have book_id = 2, 3, 4, 29, 30?")
print("Let's check if the columns in BookPages were parsed properly in repair_alhikmeh_db.py!")
