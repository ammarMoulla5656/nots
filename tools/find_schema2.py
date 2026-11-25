SOURCE_DB = r"d:\01_Projects\mobile\nots\alhikmeh.db"

with open(SOURCE_DB, "rb") as f:
    data = f.read(50 * 1024 * 1024)
    idx = 0
    found = False
    while True:
        idx = data.find(b"CREATE TABLE", idx)
        if idx == -1:
            break
        found = True
        print(f"At {idx}:", data[idx : idx + 200])
        idx += 12
    if not found:
        print("No CREATE TABLE found in first 50MB, searching case insensitive...")
        idx = data.lower().find(b"create table")
        print("Case insensitive:", idx)
