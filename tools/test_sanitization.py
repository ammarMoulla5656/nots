import sqlite3
import re

c = sqlite3.connect('library.db')
books = c.execute("SELECT DISTINCT bookID, book_name, authorName, category, cunt FROM Contents ORDER BY bookID").fetchall()

def sanitize_name(name):
    # remove punctuation that is illegal in windows filenames: \ / : * ? " < > |
    cleaned = re.sub(r'[\\/*?:"<>|]', '', name)
    # replace multiple spaces or newlines
    cleaned = re.sub(r'\s+', '_', cleaned.strip())
    return cleaned

print(f"Total books: {len(books)}")
long_names = []
for b in books:
    b_id, name, author, cat, cunt = b
    s_name = sanitize_name(name)
    if len(s_name) > 80:
        long_names.append((b_id, len(s_name), s_name))

print("Names longer than 80 chars:", len(long_names))
for ln in long_names[:5]:
    print(ln)

c.close()
