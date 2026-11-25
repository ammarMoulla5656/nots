import sqlite3

c = sqlite3.connect('alhikmeh_repaired.db')

def get_sample_pages(part_id):
    pages = c.execute("SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id", (part_id,)).fetchall()
    if not pages:
        return []
    total = len(pages)
    # pick 5 checkpoints: ~5%, ~25%, ~50%, ~75%, ~95%
    indices = [
        int(total * 0.05),
        int(total * 0.25),
        int(total * 0.50),
        int(total * 0.75),
        min(total - 1, int(total * 0.95))
    ]
    # ensure unique and valid
    indices = sorted(list(set(indices)))
    samples = []
    for idx in indices:
        p_id, txt = pages[idx]
        # clean snippet
        snippet = " ".join((txt or "").split())[:200]
        samples.append({
            "index_in_part": idx + 1,
            "source_page_id": p_id,
            "snippet": snippet
        })
    return samples

# Test on Al-Kafi part 1
print("Sample checkpoints for Al-Kafi Part 1 (part_id=1):")
for s in get_sample_pages(1):
    print(f"  Page {s['source_page_id']} (Index {s['index_in_part']}): {s['snippet'][:80]}...")

# Test on Aqaed al-Imamiyyah (part_id=346)
print("\nSample checkpoints for Aqaed al-Imamiyyah (part_id=346):")
for s in get_sample_pages(346):
    print(f"  Page {s['source_page_id']} (Index {s['index_in_part']}): {s['snippet'][:80]}...")

c.close()
