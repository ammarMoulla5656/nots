import os
from test_decode import decode_record

SOURCE_DB = r"d:\01_Projects\mobile\nots\alhikmeh.db"
PAGE_SIZE = 4096

# Search for pages mentioning الكافي or search rowid 1..1000
with open(SOURCE_DB, "rb") as f:
    for page_idx in range(3260, 3350, 5):
        f.seek(page_idx * PAGE_SIZE)
        page = f.read(PAGE_SIZE)
        if len(page) == 0 or page[0] != 0x0d:
            continue
        num_cells = int.from_bytes(page[3:5], "big")
        for ci in range(min(num_cells, 1)):
            ptr_off = 8 + 2 * ci
            ptr = int.from_bytes(page[ptr_off : ptr_off + 2], "big")
            rowid, sts, vals = decode_record(page, ptr)
            if rowid is not None and isinstance(vals, list) and len(vals) == 5:
                print(f"rowid={rowid}, sts={sts}, vals={vals[:4]}")
