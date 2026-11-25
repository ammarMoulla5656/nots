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

with open(SOURCE_DB, "rb") as f:
    f.seek(3269 * PAGE_SIZE)
    page = f.read(PAGE_SIZE)
    num_cells = int.from_bytes(page[3:5], "big")
    ptr_off = 8
    ptr = int.from_bytes(page[ptr_off : ptr_off + 2], "big")
    payload_len, off = read_varint(page, ptr)
    rowid, off = read_varint(page, off)
    hdr_len, val_off = read_varint(page, off)
    hdr_end = off + hdr_len
    cur = val_off
    sts = []
    while cur < hdr_end:
        st, cur = read_varint(page, cur)
        sts.append(st)
    print(f"rowid: {rowid}, payload_len: {payload_len}, hdr_len: {hdr_len}")
    print("sts:", sts)
    print("raw bytes after hdr:")
    raw = page[hdr_end : ptr + min(payload_len, 50)]
    print(list(raw[:20]))

