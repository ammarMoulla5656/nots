import sqlite3
import time
import os
from concurrent.futures import ProcessPoolExecutor

def test_worker(part_id):
    t0 = time.time()
    c = sqlite3.connect('alhikmeh_repaired.db')
    pages = c.execute("SELECT page_id, substr(text, 1, 50) FROM BookPages WHERE part_id=?", (part_id,)).fetchall()
    c.close()
    return part_id, len(pages), time.time() - t0

if __name__ == '__main__':
    t_all = time.time()
    with ProcessPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(test_worker, [1, 2, 3, 4, 5, 6, 7, 8]))
    print(f"8 parts read concurrently in {time.time() - t_all:.2f}s:")
    for r in results:
        print(f"  Part {r[0]}: {r[1]} pages in {r[2]:.2f}s")
