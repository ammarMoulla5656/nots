# -*- coding: utf-8 -*-
"""
=============================================================================
أداة التنزيل الدفعي الشامل لكافة ملفات الـ PDF المعتمدة (1200 مجلد - 250 كتاباً)
=============================================================================
- تقرأ أفضل روابط الـ PDF المعتمدة من قاعدة البيانات (matching_database.json).
- تدعم التنزيل المتوازي السريع (Multi-threading) مع الاستئناف التلقائي (Resume).
- إذا تعذر التحميل من الرابط الأساسي، تجرب تلقائياً الروابط البديلة المعتمدة لنفس الجزء.
- تحفظ كل ملف PDF بنفس اسم وترتيب ملف الـ DOCX المقابل له داخل مجلد: كتب_المكتبة_PDF
=============================================================================
"""

import os
import re
import sys
import json
import time
import urllib.request
import concurrent.futures

BASE_DIR = r"d:\01_Projects\mobile\nots"
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
PDF_OUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_PDF")
os.makedirs(PDF_OUT_DIR, exist_ok=True)

def resolve_direct_pdf_stream_url(url):
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=20.0) as resp:
            final_url = resp.geturl()
            ctype = resp.headers.get("Content-Type", "").lower()
            if "mediafire.com" in final_url and "text/html" in ctype:
                html = resp.read().decode("utf-8", errors="ignore")
                m = re.search(r'href=["\'](https?://download[^"\']+\.pdf[^"\']*)["\']', html, re.I)
                if not m:
                    m = re.search(r'href=["\'](https?://download\d*\.mediafire\.com/[^"\']+)["\']', html, re.I)
                if m:
                    return m.group(1)
            return final_url
    except Exception:
        return url

def download_single_volume(item):
    key, info = item
    docx_path = info.get("docx_path", "")
    if docx_path:
        base_fn = re.sub(r"\.docx$", ".pdf", os.path.basename(docx_path))
    else:
        base_fn = f"[ID_{key}].pdf"
    target_path = os.path.join(PDF_OUT_DIR, base_fn)

    # Skip if already downloaded and valid (> 10 KB)
    if os.path.exists(target_path) and os.path.getsize(target_path) > 10240:
        return key, True, target_path, "موجود مسبقاً"

    # Build ordered list of URLs to try (primary first, then alternative direct PDFs)
    urls_to_try = []
    if info.get("pdf_url"):
        urls_to_try.append(info["pdf_url"])
    if info.get("ab_pdf_url") and info["ab_pdf_url"] not in urls_to_try:
        urls_to_try.append(info["ab_pdf_url"])
    for c in info.get("candidates", []):
        u = c.get("url", "")
        if u and u not in urls_to_try and ("/pdf" in u or u.endswith(".pdf") or "fk_dl=" in u):
            urls_to_try.append(u)

    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
    last_err = ""
    tmp_path = target_path + ".part"

    for u in urls_to_try:
        try:
            real_url = resolve_direct_pdf_stream_url(u)
            req = urllib.request.Request(real_url, headers=headers)
            with urllib.request.urlopen(req, timeout=90.0) as resp, open(tmp_path, "wb") as out_f:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    out_f.write(chunk)
            if os.path.exists(tmp_path) and os.path.getsize(tmp_path) > 10240:
                if os.path.exists(target_path):
                    os.remove(target_path)
                os.replace(tmp_path, target_path)
                return key, True, target_path, f"تم التنزيل ({os.path.getsize(target_path)//1024} KB)"
        except Exception as e:
            last_err = str(e)
            if os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except Exception:
                    pass

    return key, False, "", last_err

def main():
    if not os.path.exists(MATCHING_DB):
        print("لم يتم العثور على ملف matching_database.json")
        return

    with open(MATCHING_DB, "r", encoding="utf-8") as f:
        m_db = json.load(f)

    items = sorted(m_db.items(), key=lambda x: (int(x[0].split("_")[0]), int(x[0].split("_")[1])))
    total = len(items)
    print("=" * 72)
    print(f"بدء التنزيل الدفعي الشامل لـ {total} مجلد PDF إلى المجلد:")
    print(f"  {PDF_OUT_DIR}")
    print("=" * 72)

    t0 = time.time()
    ok_count = 0
    fail_count = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(download_single_volume, it): it[0] for it in items}
        done = 0
        for fut in concurrent.futures.as_completed(futs):
            done += 1
            key, ok, path, msg = fut.result()
            if ok:
                ok_count += 1
                m_db[key]["downloaded"] = True
                m_db[key]["local_pdf_path"] = path
            else:
                fail_count += 1
            if done % 10 == 0 or done == total:
                elapsed = time.time() - t0
                print(f"[{done:4d}/{total}] مكتمل: {ok_count} | فشل: {fail_count} | الزمن: {elapsed:.1f}s | آخر حالة ({key}): {msg}", flush=True)
                with open(MATCHING_DB, "w", encoding="utf-8") as f:
                    json.dump(m_db, f, ensure_ascii=False, indent=2)

    print("=" * 72)
    print(f"اكتملت العملية! تم تنزيل وتأكيد {ok_count} / {total} ملف PDF في:")
    print(f"  {PDF_OUT_DIR}")
    print("=" * 72)

if __name__ == "__main__":
    main()
