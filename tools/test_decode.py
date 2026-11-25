import os

SOURCE_DB = r"d:\01_Projects\mobile\nots\alhikmeh.db"
PAGE_SIZE = 4096

def read_varint(data, offset):
    res = 0
    for i in range(9):
        if offset + i >= len(data):
            return 0, len(data)
        b = data[offset + i]
        if i == 8:
            res = (res << 8) | b
            return res, offset + 9
        res = (res << 7) | (b & 0x7f)
        if (b & 0x80) == 0:
            return res, offset + i + 1
    return res, offset + 9

def decode_record(page, ptr):
    try:
        payload_len, off = read_varint(page, ptr)
        rowid, off = read_varint(page, off)
        hdr_len, val_off = read_varint(page, off)
        hdr_end = off + hdr_len
        sts = []
        cur = val_off
        while cur < hdr_end and cur < len(page):
            st, cur = read_varint(page, cur)
            sts.append(st)
        
        val_cur = hdr_end
        vals = []
        for st in sts:
            if st == 0:
                vals.append(None)
            elif st == 1:
                vals.append(int.from_bytes(page[val_cur : val_cur + 1], "big", signed=True))
                val_cur += 1
            elif st == 2:
                vals.append(int.from_bytes(page[val_cur : val_cur + 2], "big", signed=True))
                val_cur += 2
            elif st == 3:
                vals.append(int.from_bytes(page[val_cur : val_cur + 3], "big", signed=True))
                val_cur += 3
            elif st == 4:
                vals.append(int.from_bytes(page[val_cur : val_cur + 4], "big", signed=True))
                val_cur += 4
            elif st == 5:
                vals.append(int.from_bytes(page[val_cur : val_cur + 6], "big", signed=True))
                val_cur += 6
            elif st == 6:
                vals.append(int.from_bytes(page[val_cur : val_cur + 8], "big", signed=True))
                val_cur += 8
            elif st == 7:
                val_cur += 8 # float
                vals.append(0.0)
            elif st == 8:
                vals.append(0)
            elif st == 9:
                vals.append(1)
            elif st >= 12 and st % 2 == 0:
                blen = (st - 12) // 2
                val_cur += blen
                vals.append(f"<blob {blen}>")
            elif st >= 13 and st % 2 == 1:
                tlen = (st - 13) // 2
                txt = page[val_cur : val_cur + tlen].decode("utf-8", errors="ignore")
                vals.append(txt)
                val_cur += tlen
            else:
                vals.append(None)
        return rowid, sts, vals
    except Exception as e:
        return None, None, str(e)

with open(SOURCE_DB, "rb") as f:
    for page_idx in range(3200, 3250):
        f.seek(page_idx * PAGE_SIZE)
        page = f.read(PAGE_SIZE)
        if len(page) == 0 or page[0] != 0x0d:
            continue
        num_cells = int.from_bytes(page[3:5], "big")
        for ci in range(min(num_cells, 2)):
            ptr_off = 8 + 2 * ci
            ptr = int.from_bytes(page[ptr_off : ptr_off + 2], "big")
            rowid, sts, vals = decode_record(page, ptr)
            if rowid is not None and isinstance(vals, list):
                print(f"Page {page_idx}, row {rowid}:")
                print("  sts:", sts)
                print("  vals:", vals[:4], vals[4][:60] if len(vals) > 4 and isinstance(vals[4], str) else "")
