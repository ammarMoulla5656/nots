import sqlite3
import time

t0 = time.time()
conn = sqlite3.connect(r'd:\01_Projects\mobile\nots\library.db')
print("Adding index to Contents in library.db...")
conn.execute("CREATE INDEX IF NOT EXISTS idx_contents_book ON Contents(bookID, partID, pageID)")
conn.execute("CREATE INDEX IF NOT EXISTS idx_contents_part ON Contents(partID, pageID)")
conn.commit()
conn.close()
print(f"Index added in {time.time() - t0:.2f}s")
