import os

SOURCE_DB = r"d:\01_Projects\mobile\nots\alhikmeh.db"
PAGE_SIZE = 4096

def read_varint(data, offset):
    res = 0
    for i in range(9):
        b = data[offset + i]
        if i == 8:
            res = (res << 8) | b
            return res, offset + 9
        res = (res << 7) | (b & 0x7f)
        if (b & 0x80) == 0:
            return res, offset + i + 1

types_count = {}

with open(SOURCE_DB, "rb") as f:
    for page_idx in range(500): # check first 500 pages
        page = f.read(PAGE_SIZE)
        if len(page) < PAGE_SIZE:
            break
        if page[0] != 0x0d:
            continue
        num_cells = int.from_bytes(page[3:5], "big")
        if num_cells == 0 or num_cells > 500:
            continue
        for ci in range(min(num_cells, 5)):
            ptr_off = 8 + 2 * ci
            ptr = int.from_bytes(page[ptr_off : ptr_off + 2], "big")
            if ptr >= PAGE_SIZE:
                continue
            try:
                payload_len, off = read_varint(page, ptr)
                rowid, off = read_varint(page, off)
                hdr_len, val_off = read_varint(page, off)
                hdr_end = off + hdr_len
                sts = []
                cur = val_off
                while cur < hdr_end:
                    st, cur = read_varint(page, cur)
                    sts.append(st)
                
                # decode values
                val_cur = hdr_end
                vals = []
                for st in sts:
                    if st == 0:
                        vals.append(None)
                    elif 1 <= st <= 4:
                        vals.append(int.from_bytes(page[val_cur:val_cur+st], "big", signed=True))
                        val_cur += st
                    elif st >= 12 and st % 2 == 0:
                        blen = (st - 12) // 2
                        vals.append(f"<blob {blen}>")
                        val_cur += blen
                    elif st >= 13 and st % 2 == 1:
                        tlen = (st - 13) // 2
                        txt = page[val_cur : val_cur + tlen].decode("utf-8", errors="ignore")
                        vals.append(txt[:50])
                        val_cur += tlen
                    else:
                        vals.append(None)
                sig = len(vals)
                if sig not in types_count:
                    types_count[sig] = []
                if len(types_count[sig]) < 3:
                    types_count[sig].append((rowid, vals))
            except Exception as e:
                pass

for sig, samples in types_count.items():
    print(f"\n--- Signature with {sig} columns: ---")
    for s in samples:
        print(s)
