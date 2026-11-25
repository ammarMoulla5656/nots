import sqlite3

lib_path = r"d:\01_Projects\mobile\nots\library.db"
rep_path = r"d:\01_Projects\mobile\nots\alhikmeh_repaired.db"

conn = sqlite3.connect(rep_path)
conn.execute(f"ATTACH DATABASE '{lib_path}' AS lib")

query = """
SELECT 
    c.book_name, 
    c.authorName, 
    c.joze, 
    c.partID, 
    c.pageID, 
    c.title, 
    c.level,
    substr(b.text, 1, 80)
FROM lib.Contents c
JOIN BookPages b ON b.book_id = c.partID AND b.page_id = c.pageID
WHERE c.bookID = 19
LIMIT 10
"""

rows = conn.execute(query).fetchall()
print(f"Joined results for bookID=19 (الاستبصار): {len(rows)}")
for r in rows:
    print(r)

conn.close()
