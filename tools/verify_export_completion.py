import os
import sys
sys.path.append(r"d:\01_Projects\mobile\nots")
sys.path.append(r"d:\01_Projects\mobile\nots\scripts")
import sqlite3

c = sqlite3.connect('library.db')
books = c.execute("SELECT bookID, book_name, category, cunt FROM Contents GROUP BY bookID ORDER BY bookID").fetchall()

existing_files = set(f for f in os.listdir('كتب_المكتبة_docx') if f.endswith('.docx'))

from batch_export_all_books import build_all_tasks

tasks = build_all_tasks()
print(f"Total tasks planned: {len(tasks)}")

task_paths = [t[7] for t in tasks]
task_fnames = [os.path.basename(p) for p in task_paths]
print(f"Unique filenames planned: {len(set(task_fnames))}")

missing = []
for p in task_paths:
    if not os.path.exists(p):
        missing.append(p)

print(f"Missing files on disk: {len(missing)}")
for m in missing[:5]:
    print(m)

c.close()
