import sqlite3

c = sqlite3.connect('library.db')
cats = c.execute("SELECT DISTINCT category FROM Contents").fetchall()
print("Distinct categories:", [c[0] for c in cats])

for cat in cats:
    cat_id = cat[0]
    sample = c.execute("SELECT book_name FROM Contents WHERE category=? LIMIT 3", (cat_id,)).fetchall()
    print(f"Category {cat_id}: {[s[0] for s in sample]}")

c.close()
