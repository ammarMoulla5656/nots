import sqlite3

lib_path = r"d:\01_Projects\mobile\nots\library.db"
conn = sqlite3.connect(lib_path)
cur = conn.cursor()

print("Distinct books in Contents:")
rows = cur.execute("SELECT DISTINCT bookID, book_name, cunt FROM Contents LIMIT 20").fetchall()
for r in rows:
    print(r)

print("\nParts for bookID=1 (الكافي):")
rows = cur.execute("SELECT DISTINCT bookID, partID, joze, book_name FROM Contents WHERE bookID=1").fetchall()
for r in rows:
    print(r)

print("\nParts for bookID=19 (الاستبصار):")
rows = cur.execute("SELECT DISTINCT bookID, partID, joze, book_name FROM Contents WHERE bookID=19").fetchall()
for r in rows:
    print(r)

print("\nParts for bookID=34 (الميزان):")
rows = cur.execute("SELECT DISTINCT bookID, partID, joze, book_name FROM Contents WHERE bookID=34").fetchall()
for r in rows:
    print(r)

conn.close()
