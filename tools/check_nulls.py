import sqlite3

c = sqlite3.connect(r'd:\01_Projects\mobile\nots\alhikmeh_repaired.db')
print("Total rows:", c.execute("SELECT count(*) FROM BookPages").fetchone()[0])
print("Rows where book_id IS NULL:", c.execute("SELECT count(*) FROM BookPages WHERE book_id IS NULL").fetchone()[0])
print("Rows where page_id IS NULL:", c.execute("SELECT count(*) FROM BookPages WHERE page_id IS NULL").fetchone()[0])

# Check a sample of page_id IS NULL
rows = c.execute("SELECT id, book_id, part_id, page_id, substr(text, 1, 50) FROM BookPages WHERE page_id IS NULL LIMIT 5").fetchall()
print("Sample page_id IS NULL:")
for r in rows:
    print(r)

c.close()
