import os

SOURCE_DB = r"d:\01_Projects\mobile\nots\alhikmeh.db"
PAGE_SIZE = 4096

from test_decode import decode_record

with open(SOURCE_DB, "rb") as f:
    for page_idx in range(3250, 3300):
        f.seek(page_idx * PAGE_SIZE)
        page = f.read(PAGE_SIZE)
        if len(page) == 0 or page[0] != 0x0d:
            continue
        num_cells = int.from_bytes(page[3:5], "big")
        for ci in range(min(num_cells, 2)):
            ptr_off = 8 + 2 * ci
            ptr = int.from_bytes(page[ptr_off : ptr_off + 2], "big")
            rowid, sts, vals = decode_record(page, ptr)
            if rowid is not None and isinstance(vals, list) and len(vals) > 2:
                print(f"Page {page_idx}, row {rowid}, cols={len(vals)}:")
                print("  sts:", sts[:6])
                sample_vals = [str(v)[:30] if v is not None else "None" for v in vals[:6]]
                print("  vals:", sample_vals)
