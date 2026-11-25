import sqlite3

c1 = sqlite3.connect('alhikmeh_repaired.db')
c2 = sqlite3.connect('library.db')

parts_bp = set(r[0] for r in c1.execute("SELECT DISTINCT part_id FROM BookPages").fetchall() if r[0] is not None)
parts_lib = set(r[0] for r in c2.execute("SELECT DISTINCT partID FROM Contents").fetchall() if r[0] is not None)

matched_parts = parts_bp & parts_lib
print(f"Parts in BookPages: {len(parts_bp)}")
print(f"Parts in Library Contents: {len(parts_lib)}")
print(f"Matched Parts: {len(matched_parts)} (out of {len(parts_lib)})")

# Check books
books_lib = c2.execute("SELECT bookID, book_name, cunt, authorName FROM Contents GROUP BY bookID").fetchall()
print(f"Total books in Contents: {len(books_lib)}")

# For each book, check how many parts matched
fully_matched_books = 0
partially_matched_books = 0
unmatched_books = 0

for b_id, name, count, author in books_lib:
    b_parts = set(r[0] for r in c2.execute("SELECT DISTINCT partID FROM Contents WHERE bookID=?", (b_id,)).fetchall())
    matched = b_parts & parts_bp
    if len(matched) == len(b_parts):
        fully_matched_books += 1
    elif len(matched) > 0:
        partially_matched_books += 1
    else:
        unmatched_books += 1

print(f"Fully matched books: {fully_matched_books}")
print(f"Partially matched books: {partially_matched_books}")
print(f"Unmatched books: {unmatched_books}")

c1.close()
c2.close()
