"""Builds geo.sqlite (IP range start -> country) from the DB-IP Lite CSV.

    python build_geo.py dbip-country-lite-YYYY-MM.csv.gz geo.sqlite

IPv4 starts are stored as IPv4-mapped IPv6 (16 bytes), as lib.php looks
them up.
"""
import csv
import gzip
import ipaddress
import os
import sqlite3
import sys

src, out = sys.argv[1], sys.argv[2]
if os.path.exists(out):
    os.remove(out)
db = sqlite3.connect(out)
db.execute("CREATE TABLE ip (start BLOB PRIMARY KEY, cc TEXT NOT NULL) WITHOUT ROWID")


def key(s: str) -> bytes:
    a = ipaddress.ip_address(s)
    return b"\0" * 10 + b"\xff\xff" + a.packed if a.version == 4 else a.packed


with gzip.open(src, "rt") as f:
    db.executemany(
        "INSERT OR REPLACE INTO ip VALUES (?, ?)",
        ((key(start), cc) for start, _end, cc in csv.reader(f)),
    )
db.commit()
db.execute("VACUUM")
db.close()
print("built", out)
