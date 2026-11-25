import sqlite3

c = sqlite3.connect('alhikmeh_repaired.db')
c.execute("ATTACH DATABASE 'library.db' AS lib")
matched_parts = c.execute("SELECT count(DISTINCT c.partID) FROM lib.Contents c JOIN BookPages b ON b.part_id = c.partID").fetchone()[0]
matched_books = c.execute("SELECT count(DISTINCT c.bookID) FROM lib.Contents c JOIN BookPages b ON b.part_id = c.partID").fetchone()[0]
print(f"Matched parts: {matched_parts} out of 1200")
print(f"Matched books: {matched_books} out of 250")
c.close()
