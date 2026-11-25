# -*- coding: utf-8 -*-
"""
=============================================================================
استوديو التحقق والمطابقة وتنزيل ملفات PDF مع ملفات الـ DOCX
Book PDF & DOCX Verification + Auto-Download Studio
=============================================================================
"""

import os
import sys
import re
import json
import time
import sqlite3
import difflib
import subprocess
import webbrowser
import threading
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = False

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the project root: this file lives in scripts/
REPAIRED_DB = os.path.join(BASE_DIR, "alhikmeh_repaired.db")
LIBRARY_DB = os.path.join(BASE_DIR, "library.db")
MATCHING_DB = os.path.join(BASE_DIR, "matching_database.json")
EXCEL_PATH = os.path.join(BASE_DIR, "تقرير_مطابقة_كتب_PDF_الشامل.xlsx")
DOCX_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_docx")
PDF_OUT_DIR = os.path.join(BASE_DIR, "كتب_المكتبة_PDF")
os.makedirs(PDF_OUT_DIR, exist_ok=True)

sys.path.append(BASE_DIR)
from tools.generate_matching_excel import generate_excel_catalog, CATEGORY_FULL

_DIACRITICS = re.compile(r"[\u064B-\u065F\u0670\u0640\u200c\u200d\u200e\u200f\ufeff]")
_NOT_LETTERS = re.compile(r"[^\w\s]", re.UNICODE)
_LETTERS_MAP = str.maketrans({
    "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
    "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي", "ی": "ي", "ک": "ك"
})

# Active download tracking
DOWNLOAD_QUEUE_STATUS = {
    "active": 0,
    "completed": 0,
    "failed": 0,
    "last_file": "",
    "items": {}  # key -> {"status": "downloading"|"done"|"error", "path": ..., "msg": ...}
}
_STATE_LOCK = threading.Lock()

def normalize_text(text):
    if not text:
        return ""
    clean = re.sub(r"<[^>]+>", " ", str(text))
    clean = _DIACRITICS.sub("", clean).translate(_LETTERS_MAP)
    clean = _NOT_LETTERS.sub(" ", clean)
    return " ".join(clean.split())

def calculate_similarity(t1, t2):
    n1 = normalize_text(t1)
    n2 = normalize_text(t2)
    if not n1 or not n2:
        return 0.0
    words1 = n1.split()[:200]
    words2 = n2.split()[:200]
    s1 = " ".join(words1)
    s2 = " ".join(words2)
    if len(s1) > 40 and (s1 in s2 or s2 in s1):
        return 98.5
    return round(difflib.SequenceMatcher(None, s1, s2).ratio() * 100, 1)

def load_matching_state():
    if os.path.exists(MATCHING_DB):
        try:
            with open(MATCHING_DB, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_matching_state(data):
    with _STATE_LOCK:
        with open(MATCHING_DB, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

def get_checkpoints_for_part(part_id):
    conn = sqlite3.connect(REPAIRED_DB)
    pages = conn.execute("SELECT page_id, text FROM BookPages WHERE part_id=? ORDER BY page_id", (part_id,)).fetchall()
    conn.close()

    if not pages:
        return []

    total = len(pages)
    positions = [
        ("بداية الجزء", int(total * 0.05)),
        ("الربع الأول", int(total * 0.25)),
        ("منتصف الجزء", int(total * 0.50)),
        ("الربع الأخير", int(total * 0.75)),
        ("نهاية الجزء", min(total - 1, int(total * 0.95)))
    ]

    checkpoints = []
    seen = set()
    for label, idx in positions:
        idx = max(0, min(total - 1, idx))
        p_id, txt = pages[idx]
        if p_id in seen:
            continue
        seen.add(p_id)
        checkpoints.append({
            "label": label,
            "source_page_id": p_id,
            "index_in_book": idx + 1,
            "text": txt or ""
        })
    return checkpoints

def get_page_text(part_id, page_id):
    conn = sqlite3.connect(REPAIRED_DB)
    row = conn.execute("SELECT text FROM BookPages WHERE part_id=? AND page_id=?", (part_id, page_id)).fetchone()
    conn.close()
    return row[0] if row else ""

def fetch_masaha_page(part_id, page_id, ab_book_id=""):
    result = {"text": "", "image": "", "status": "ok"}
    headers = {'User-Agent': 'Mozilla/5.0'}

    if part_id < 7000:
        text_url = f"https://www.masaha.org/api/book/{part_id}/get-page/{page_id}/1"
        try:
            req = urllib.request.Request(text_url, headers=headers)
            with urllib.request.urlopen(req, timeout=3.5) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                records = data.get('data', {}).get('records', [])
                if records:
                    result["text"] = records[0].get('text', '')
        except Exception:
            pass

        img_url = f"https://www.masaha.org/api/book/{part_id}/get-page-image/{page_id}"
        try:
            req = urllib.request.Request(img_url, headers=headers)
            with urllib.request.urlopen(req, timeout=3.5) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                img_data = data.get('data', '')
                if img_data and isinstance(img_data, str) and img_data.startswith('data:image'):
                    result["image"] = img_data
        except Exception:
            pass

    if ab_book_id and (not result["text"] or not result["image"]):
        ab_headers = {
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "User-Agent": "Mozilla/5.0"
        }
        if not result["text"]:
            try:
                u = "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/HTMLContents"
                payload = json.dumps({"bookId": str(ab_book_id), "pageNumbers": [page_id]}).encode("utf-8")
                req = urllib.request.Request(u, data=payload, headers=ab_headers, method="POST")
                with urllib.request.urlopen(req, timeout=4.0) as resp:
                    resp_obj = json.loads(resp.read().decode("utf-8"))
                    html_data = resp_obj.get("data", "")
                    if html_data:
                        result["text"] = re.sub(r"<[^>]+>", " ", html_data).strip()
                    else:
                        contents = resp_obj.get("contents", [])
                        if contents:
                            result["text"] = re.sub(r"<[^>]+>", " ", contents[0].get("html", "")).strip()
            except Exception:
                pass
        if not result["image"]:
            try:
                u = "https://grpc.ablibrary.net/ablibrary.services.book_service.BookService/PDFPages"
                payload = json.dumps({"bookId": str(ab_book_id), "basic": {"numbers": [page_id]}}).encode("utf-8")
                req = urllib.request.Request(u, data=payload, headers=ab_headers, method="POST")
                with urllib.request.urlopen(req, timeout=4.0) as resp:
                    pages = json.loads(resp.read().decode("utf-8")).get("pages", {})
                    p_obj = pages.get(str(page_id)) or {}
                    if p_obj.get("url"):
                        result["image"] = p_obj["url"]
            except Exception:
                pass

    return result

def resolve_direct_pdf_stream_url(url):
    """If url redirects to MediaFire or similar landing page, extract actual direct binary PDF URL."""
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15.0) as resp:
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

def download_pdf_worker(key, pdf_url):
    state = load_matching_state()
    info = state.get(key, {})
    docx_path = info.get("docx_path", "")
    if docx_path:
        base_fn = re.sub(r"\.docx$", ".pdf", os.path.basename(docx_path))
    else:
        base_fn = f"[ID_{key}].pdf"
    target_path = os.path.join(PDF_OUT_DIR, base_fn)

    DOWNLOAD_QUEUE_STATUS["active"] += 1
    DOWNLOAD_QUEUE_STATUS["items"][key] = {"status": "downloading", "path": target_path, "msg": "جاري التنزيل..."}

    try:
        real_url = resolve_direct_pdf_stream_url(pdf_url)
        headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
        req = urllib.request.Request(real_url, headers=headers)
        with urllib.request.urlopen(req, timeout=60.0) as resp, open(target_path, "wb") as out_f:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                out_f.write(chunk)

        if os.path.exists(target_path) and os.path.getsize(target_path) > 1024:
            st = load_matching_state()
            if key in st:
                st[key]["downloaded"] = True
                st[key]["local_pdf_path"] = target_path
                st[key]["status"] = "مطابق"
                save_matching_state(st)
            DOWNLOAD_QUEUE_STATUS["completed"] += 1
            DOWNLOAD_QUEUE_STATUS["last_file"] = base_fn
            DOWNLOAD_QUEUE_STATUS["items"][key] = {"status": "done", "path": target_path, "msg": "تم التنزيل بنجاح ✔️"}
        else:
            DOWNLOAD_QUEUE_STATUS["failed"] += 1
            DOWNLOAD_QUEUE_STATUS["items"][key] = {"status": "error", "path": "", "msg": "الملف المنزل صغير جداً أو صفحة ويب"}
    except Exception as e:
        DOWNLOAD_QUEUE_STATUS["failed"] += 1
        DOWNLOAD_QUEUE_STATUS["items"][key] = {"status": "error", "path": "", "msg": str(e)}
    finally:
        DOWNLOAD_QUEUE_STATUS["active"] = max(0, DOWNLOAD_QUEUE_STATUS["active"] - 1)

# =============================================================================
# واجهة الويب المتكاملة HTML5 + CSS3 + JS
# =============================================================================
HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>استوديو التحقق والمطابقة وتنزيل ملفات PDF مع الـ DOCX</title>
<link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;600;700;800&family=Amiri:wght@400;700&display=swap" rel="stylesheet">
<style>
:root {
  --primary: #1B365D;
  --primary-light: #2A4D7D;
  --accent: #B8860B;
  --success: #1E7E34;
  --danger: #BD2130;
  --warning: #E0A800;
  --info: #0069D9;
  --bg-light: #F4F6F9;
  --border: #DDE2E5;
}

* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: 'Cairo', sans-serif;
  background-color: var(--bg-light);
  color: #333;
  height: 100vh;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

header {
  background: var(--primary);
  color: white;
  padding: 8px 18px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  box-shadow: 0 2px 8px rgba(0,0,0,0.15);
  z-index: 10;
}

.brand {
  display: flex;
  align-items: center;
  gap: 10px;
}
.brand h1 { font-size: 1.15rem; font-weight: 700; }
.badge-sub {
  background: rgba(255,255,255,0.18);
  padding: 4px 12px;
  border-radius: 12px;
  font-size: 0.8rem;
  font-weight: 600;
}

.top-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

button {
  cursor: pointer;
  border: none;
  border-radius: 6px;
  padding: 6px 12px;
  font-family: 'Cairo', sans-serif;
  font-size: 0.85rem;
  font-weight: 700;
  transition: all 0.15s ease;
  display: inline-flex;
  align-items: center;
  gap: 5px;
}

.btn-primary { background: var(--accent); color: white; }
.btn-primary:hover { background: #996515; }
.btn-success { background: var(--success); color: white; }
.btn-success:hover { background: #155724; }
.btn-danger { background: var(--danger); color: white; }
.btn-danger:hover { background: #721c24; }
.btn-warning { background: var(--warning); color: #212529; }
.btn-warning:hover { background: #d39e00; }
.btn-info { background: var(--info); color: white; }
.btn-info:hover { background: #0056b3; }
.btn-outline { background: white; border: 1px solid var(--border); color: #333; }
.btn-outline:hover { background: #e9ecef; }

.control-bar {
  background: white;
  border-bottom: 1px solid var(--border);
  padding: 8px 18px;
  display: flex;
  gap: 12px;
  align-items: center;
  flex-wrap: wrap;
}

.filter-group {
  display: flex;
  align-items: center;
  gap: 6px;
}

select, input[type="text"], input[type="number"] {
  padding: 6px 10px;
  border: 1px solid var(--border);
  border-radius: 6px;
  font-family: 'Cairo', sans-serif;
  font-size: 0.88rem;
}

.main-content {
  display: flex;
  flex: 1;
  overflow: hidden;
  padding: 8px 12px;
  gap: 12px;
}

.panel {
  flex: 1;
  background: white;
  border-radius: 8px;
  border: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  box-shadow: 0 1px 4px rgba(0,0,0,0.05);
}

.panel-header {
  background: #F8FAFC;
  border-bottom: 1px solid var(--border);
  padding: 8px 14px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

.panel-title {
  font-weight: 700;
  font-size: 0.96rem;
  color: var(--primary);
  display: flex;
  align-items: center;
  gap: 8px;
}

.checkpoints-tabs {
  display: flex;
  background: #EEF2F6;
  border-bottom: 1px solid var(--border);
  overflow-x: auto;
}

.tab-btn {
  padding: 7px 12px;
  border: none;
  background: transparent;
  color: #555;
  font-size: 0.82rem;
  border-radius: 0;
  border-bottom: 3px solid transparent;
}

.tab-btn.active {
  background: white;
  color: var(--primary);
  font-weight: 700;
  border-bottom-color: var(--primary);
}

.panel-body {
  padding: 15px;
  overflow-y: auto;
  flex: 1;
  font-family: 'Amiri', serif;
  font-size: 1.22rem;
  line-height: 2.05;
  background: #FCFCFD;
  white-space: pre-wrap;
}

.page-badge {
  display: inline-block;
  background: #E8EFF7;
  color: var(--primary);
  padding: 4px 10px;
  border-radius: 4px;
  font-size: 0.84rem;
  font-weight: 700;
  margin-bottom: 10px;
  font-family: 'Cairo', sans-serif;
}

.actions-bar {
  background: #F8FAFC;
  border-top: 1px solid var(--border);
  padding: 8px 14px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

.links-group {
  display: flex;
  gap: 8px;
  align-items: center;
  background: #EBF3FB;
  padding: 6px 12px;
  font-size: 0.82rem;
  flex-wrap: wrap;
}
.links-group a {
  color: var(--primary);
  text-decoration: none;
  font-weight: 700;
}
.links-group a:hover { text-decoration: underline; }

.offset-box {
  display: flex;
  align-items: center;
  gap: 5px;
  background: #FFF;
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 2px 8px;
}

.similarity-badge {
  padding: 4px 12px;
  border-radius: 12px;
  font-size: 0.88rem;
  font-weight: 700;
}
.score-high { background: #D4EDDA; color: #155724; }
.score-mid { background: #FFF3CD; color: #856404; }
.score-low { background: #F8D7DA; color: #721C24; }

.status-indicator {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 0.82rem;
  padding: 4px 10px;
  border-radius: 6px;
  font-weight: 700;
}
.status-has-pdf { background: #D4EDDA; color: #155724; }
.status-no-pdf { background: #FFF3CD; color: #856404; }

.view-toggle {
  display: flex;
  gap: 4px;
  background: #E2E8F0;
  padding: 3px;
  border-radius: 6px;
}
.view-toggle button {
  padding: 3px 8px;
  font-size: 0.76rem;
  background: transparent;
  color: #4A5568;
}
.view-toggle button.active {
  background: white;
  color: var(--primary);
  box-shadow: 0 1px 2px rgba(0,0,0,0.1);
}

.scan-image-box {
  display: flex;
  justify-content: center;
  align-items: flex-start;
  min-height: 100%;
}
.scan-image-box img {
  max-width: 100%;
  height: auto;
  border-radius: 4px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.15);
}
</style>
</head>
<body>

<header>
  <div class="brand">
    <span style="font-size: 1.5rem;">📖</span>
    <div>
      <h1>استوديو التحقق والمطابقة وتنزيل ملفات PDF مع الـ DOCX</h1>
      <span id="dlStatusBanner" style="font-size: 0.78rem; color: #FFD700; font-weight: 600;">جاهز للتحقق والتنزيل المباشر إلى مجلد كتب_المكتبة_PDF</span>
    </div>
  </div>
  
  <div class="top-actions">
    <span id="statsBadge" class="badge-sub">جاري التحميل...</span>
    <button class="btn-success" onclick="downloadAllAbove90()">⚡ تنزيل كل ملفات الـ PDF المعتمدة (1200 مجلد) دفعة واحدة</button>
    <button class="btn-info" onclick="openFolder('pdf_dir')">📂 مجلد الـ PDF المنزل</button>
    <button class="btn-primary" onclick="exportToExcel()">📊 تحديث وفتح ملف الإكسل</button>
  </div>
</header>

<div class="control-bar">
  <div class="filter-group">
    <label><strong>تصفية العرض:</strong></label>
    <select id="filterSelect" onchange="applyFilter()" style="min-width: 260px; font-weight: bold; background: #FFFDF5; border-color: #B8860B;">
      <option value="all" selected>📚 جميع المجلدات المعتمدة (1200 مجلد)</option>
      <option value="above_90">✔️ فوق 90% تطابق ممتاز (1200 مجلد)</option>
      <option value="under_90">⚠️ أقل من 90% تطابق (0 مجلد)</option>
      <option value="downloaded">📥 تم تنزيل الـ PDF في الجهاز</option>
      <option value="rejected">❌ المرفوضة (تحتاج رابط آخر)</option>
    </select>
  </div>

  <div class="filter-group" style="flex: 1;">
    <label><strong>الكتاب:</strong></label>
    <select id="bookSelect" style="flex: 1; max-width: 460px; font-weight: 700;" onchange="onBookChange()"></select>
  </div>

  <div class="filter-group">
    <label><strong>الجزء:</strong></label>
    <select id="partSelect" style="width: 135px; font-weight: 700;" onchange="onPartChange()"></select>
    <button class="btn-outline" onclick="prevPart()">◀ السابق</button>
    <button class="btn-outline" onclick="nextPart()">التالي ▶</button>
  </div>

  <div id="masahaStatusBadge" class="status-indicator status-has-pdf">🟢 جاهز</div>
</div>

<div class="main-content">
  <!-- الجانب الأيمن: نص المصدر وملف الـ DOCX -->
  <div class="panel">
    <div class="panel-header">
      <div class="panel-title">
        <span>📜 نص المصدر (ملف الـ DOCX)</span>
        <span id="sourceTitle" style="font-size: 0.84rem; color: #555;"></span>
      </div>
      <div style="display: flex; gap: 6px; align-items: center;">
        <button class="btn-info" onclick="openCurrentDocx()">📄 فتح ملف الـ DOCX في وورد</button>
      </div>
    </div>
    <div id="sourceMeta" style="padding: 4px 14px; background: #F1F5F9; font-size: 0.8rem; color: #475569; border-bottom: 1px solid var(--border);"></div>
    <div class="checkpoints-tabs" id="tabsBar"></div>
    <div class="panel-body" id="sourceBody"></div>
    <div class="actions-bar">
      <div id="sourcePageNav" style="display: flex; gap: 6px; align-items: center; font-size: 0.86rem;">
        <span>رقم صفحة المصدر:</span>
        <input type="number" id="manualPageInput" style="width: 75px;" onchange="onManualPageChange()">
        <button class="btn-outline" style="padding: 4px 10px;" onclick="loadManualPage()">عرض الصفحة</button>
      </div>
      <div>
        <span style="font-size: 0.8rem; color: #777;">* الترقيم مطابق لنسخة المطبوع وملف الـ DOCX</span>
      </div>
    </div>
  </div>

  <!-- الجانب الأيسر: ملف الـ PDF والروابط البديلة والتنزيل -->
  <div class="panel">
    <div class="panel-header">
      <div class="panel-title">
        <span>🔍 فحص ومطابقة الـ PDF</span>
        <div class="view-toggle">
          <button id="viewToggleScan" class="active" onclick="setViewMode('scan')">صورة سكان الصفحة</button>
          <button id="viewToggleText" onclick="setViewMode('text')">النص المقابل</button>
          <button id="viewTogglePdf" onclick="setViewMode('pdf')">معاينة الـ PDF كامل</button>
        </div>
      </div>
      <div style="display: flex; gap: 6px; align-items: center;">
        <button id="openLocalPdfBtn" class="btn-success" style="display: none; padding: 4px 10px; font-size: 0.8rem;" onclick="openCurrentLocalPdf()">📕 فتح الـ PDF المنزل بالجهاز</button>
        <div id="similarityBox" class="similarity-badge score-high">نسبة التطابق: --%</div>
      </div>
    </div>

    <div class="links-group" style="border-bottom: 1px solid var(--border); justify-content: space-between;">
      <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap;">
        <a id="masahaLink" href="#" target="_blank">🌐 مساحة حرة</a>
        <span>|</span>
        <a id="ablibraryLink" href="#" target="_blank">🏛️ مكتبة أهل البيت</a>
        <span>|</span>
        <a id="alfekerLink" href="#" target="_blank">📖 شبكة الفكر</a>
        <span>|</span>
        <a id="googlePdfLink" href="#" target="_blank">🔎 بحث Google PDF</a>
      </div>
      <a id="pdfDirectLink" href="#" target="_blank" style="color: #B8860B; font-weight: 800;">📥 فتح رابط الـ PDF في نافذة جديدة ↗</a>
    </div>

    <!-- شريط اختيار النسخ والروابط البديلة -->
    <div style="padding: 6px 12px; background: #F8FAFC; border-bottom: 1px solid var(--border); display: flex; gap: 6px; align-items: center; flex-wrap: wrap;">
      <label style="font-size: 0.8rem; white-space: nowrap;"><strong>الروابط المتوفرة:</strong></label>
      <select id="candidateSelect" style="max-width: 240px; font-size: 0.82rem; font-weight: 600;" onchange="onCandidateSelectChange()"></select>
      <input type="text" id="pdfUrlInput" placeholder="رابط الـ PDF المعتمد أو الصق رابطاً بديلاً هنا..." style="flex: 1; min-width: 180px; font-size: 0.82rem;" onchange="onPdfUrlChange()">
      <button class="btn-outline" style="padding: 4px 8px; font-size: 0.78rem;" onclick="testCustomUrl()">فتح الرابط</button>
    </div>

    <div class="panel-body" id="candidateBody" style="background: #FAFAFC;"></div>

    <div class="actions-bar">
      <div class="offset-box">
        <span style="font-size: 0.82rem;"><strong>الإزاحة (Offset):</strong></span>
        <button class="btn-outline" style="padding: 3px 7px;" onclick="adjustOffset(-5)">-5</button>
        <button class="btn-outline" style="padding: 3px 7px;" onclick="adjustOffset(-1)">-1</button>
        <span id="offsetVal" style="font-weight: 700; min-width: 26px; text-align: center;">0</span>
        <button class="btn-outline" style="padding: 3px 7px;" onclick="adjustOffset(+1)">+1</button>
        <button class="btn-outline" style="padding: 3px 7px;" onclick="adjustOffset(+5)">+5</button>
      </div>

      <div style="display: flex; gap: 6px; flex-wrap: wrap;">
        <button class="btn-danger" onclick="rejectAndTryNext()">❌ رفض / تجربة رابط ثاني</button>
        <button class="btn-warning" onclick="approveOnly()">✔️ اعتماد فقط</button>
        <button class="btn-success" onclick="approveAndDownload()">📥 موافقة وتنزيل الـ PDF للجهاز (ويعبر)</button>
      </div>
    </div>
  </div>
</div>

<script>
const API_BASE = window.location.protocol === 'file:' ? 'http://127.0.0.1:8500' : '';
let allBooks = __INITIAL_BOOKS__;
let filteredBooks = [];
let currentBook = null;
let currentParts = [];
let currentPartIndex = 0;
let currentPartData = null;
let currentCheckpoints = [];
let currentTabIdx = 0;
let currentOffset = 0;
let matchingState = __INITIAL_STATE__;
let currentViewMode = 'scan'; // 'scan', 'text', or 'pdf'
let currentCandidateData = { text: '', image: '', score: 0 };

async function init() {
  try {
    if (!allBooks || allBooks.length === 0) {
      const res = await fetch(`${API_BASE}/api/books`);
      allBooks = await res.json();
    }
    if (!matchingState || Object.keys(matchingState).length === 0) {
      const stateRes = await fetch(`${API_BASE}/api/get_state`);
      matchingState = await stateRes.json();
    }
    applyFilter();
    updateStats();
    setInterval(pollDownloadStatus, 2500);
  } catch (err) {
    console.error('Error during init:', err);
    if (allBooks && allBooks.length > 0) {
      applyFilter();
      updateStats();
    }
  }
}

async function pollDownloadStatus() {
  try {
    const res = await fetch(`${API_BASE}/api/download_status`);
    const st = await res.json();
    const banner = document.getElementById('dlStatusBanner');
    if (st.active > 0) {
      banner.textContent = `⏳ جاري تنزيل ${st.active} ملف PDF في الخلفية... (اكتمل: ${st.completed} | آخر ملف: ${st.last_file || '-'})`;
    } else if (st.completed > 0) {
      banner.textContent = `✔️ اكتمل تنزيل ${st.completed} ملف PDF في مجلد كتب_المكتبة_PDF (آخر ملف: ${st.last_file})`;
    }
  } catch (e) {}
}

function isPartMatchingFilter(bId, pId, mode) {
  const key = `${bId}_${pId}`;
  const st = matchingState[key] || {};
  const sc = parseFloat(st.score) || 0;
  const isRej = (st.status || '').includes('غير مطابق') || (st.status || '').includes('مرفوض');
  if (mode === 'all') return true;
  if (mode === 'under_90') return sc < 90.0 || isRej;
  if (mode === 'above_90') return sc >= 90.0 && !isRej;
  if (mode === 'under_70') return sc < 70.0 || isRej;
  if (mode === 'downloaded') return Boolean(st.downloaded);
  if (mode === 'rejected') return isRej;
  return true;
}

function applyFilter() {
  const mode = document.getElementById('filterSelect').value;
  filteredBooks = allBooks.filter(b => b.parts.some(p => isPartMatchingFilter(b.bookID, p.partID, mode)));

  populateBooksDropdown(mode);
  if (filteredBooks.length > 0) {
    onBookChange();
  } else {
    document.getElementById('partSelect').innerHTML = '';
    document.getElementById('sourceBody').innerHTML = '<div style="padding:30px; text-align:center; color:#666;">لا توجد مجلدات ضمن هذا الفلتر حالياً. اختر "جميع المجلدات" من القائمة أعلاه.</div>';
    document.getElementById('candidateBody').innerHTML = '';
  }
}

function populateBooksDropdown(mode) {
  const sel = document.getElementById('bookSelect');
  sel.innerHTML = '';
  if (!filteredBooks || filteredBooks.length === 0) {
    const opt = document.createElement('option');
    opt.textContent = '-- لا توجد نتائج لهذا الفلتر --';
    sel.appendChild(opt);
    return;
  }
  
  filteredBooks.forEach(b => {
    const opt = document.createElement('option');
    opt.value = b.bookID;
    
    let minScore = 100;
    let dlCount = 0;
    b.parts.forEach(p => {
      const st = matchingState[`${b.bookID}_${p.partID}`] || {};
      const sc = parseFloat(st.score) || 0;
      if (sc < minScore) minScore = sc;
      if (st.downloaded) dlCount++;
    });
    
    const badge = dlCount === b.parts.length ? '📥 ' : (minScore >= 90 ? '✔️ ' : `⚠️ (${minScore}%) `);
    opt.textContent = `${badge}[ID_${b.bookID}] ${b.book_name} (${b.parts.length} ج)`;
    sel.appendChild(opt);
  });
  
  sel.selectedIndex = 0;
}

function updateStats() {
  let above90 = 0, under90 = 0, downloaded = 0, total = 0;
  allBooks.forEach(b => {
    b.parts.forEach(p => {
      total++;
      const st = matchingState[`${b.bookID}_${p.partID}`] || {};
      const sc = parseFloat(st.score) || 0;
      if (sc >= 90.0) above90++;
      else under90++;
      if (st.downloaded) downloaded++;
    });
  });
  document.getElementById('statsBadge').textContent = `فوق 90% (✔️): ${above90} | تحت 90% (⚠️ للتحقق): ${under90} | تم تنزيله بالجهاز (📥): ${downloaded}/${total}`;
}

async function onBookChange() {
  const sel = document.getElementById('bookSelect');
  if (!sel || !sel.value) return;
  const bId = parseInt(sel.value);
  currentBook = allBooks.find(b => b.bookID === bId);
  if (!currentBook) return;

  const mode = document.getElementById('filterSelect').value;
  const matchingParts = currentBook.parts.filter(p => isPartMatchingFilter(bId, p.partID, mode));
  currentParts = matchingParts.length > 0 ? matchingParts : currentBook.parts;
  
  const pSel = document.getElementById('partSelect');
  pSel.innerHTML = '';
  currentParts.forEach((p, idx) => {
    const opt = document.createElement('option');
    opt.value = idx;
    const st = matchingState[`${bId}_${p.partID}`] || {};
    const sc = parseFloat(st.score) || 0;
    const icon = st.downloaded ? '📥 ' : (sc >= 90 ? '✔️ ' : '⚠️ ');
    opt.textContent = `${icon}${p.label} (${sc}%)`;
    pSel.appendChild(opt);
  });
  
  currentPartIndex = 0;
  loadCurrentPart();
}

function onPartChange() {
  currentPartIndex = parseInt(document.getElementById('partSelect').value);
  loadCurrentPart();
}

function prevPart() {
  if (currentPartIndex > 0) {
    currentPartIndex--;
    document.getElementById('partSelect').value = currentPartIndex;
    loadCurrentPart();
  } else {
    const bSel = document.getElementById('bookSelect');
    if (bSel.selectedIndex > 0) {
      bSel.selectedIndex--;
      onBookChange();
    }
  }
}

function nextPart() {
  if (currentPartIndex < currentParts.length - 1) {
    currentPartIndex++;
    document.getElementById('partSelect').value = currentPartIndex;
    loadCurrentPart();
  } else {
    const bSel = document.getElementById('bookSelect');
    if (bSel.selectedIndex < bSel.options.length - 1) {
      bSel.selectedIndex++;
      onBookChange();
    }
  }
}

async function loadCurrentPart() {
  const part = currentParts[currentPartIndex];
  if (!part) return;
  const bId = currentBook.bookID;
  const pId = part.partID;
  const key = `${bId}_${pId}`;
  const saved = matchingState[key] || {};
  const sc = parseFloat(saved.score) || 0;

  document.getElementById('sourceTitle').textContent = `[ID_${bId}] ${currentBook.book_name} - ${part.label}`;
  document.getElementById('sourceMeta').textContent = `المؤلف: ${currentBook.authorName || '-'} | التصنيف: ${currentBook.category_name} | ملف الـ DOCX: ${saved.docx_path ? 'متوفر في الجهاز ✔️' : '-'}`;

  const qName = encodeURIComponent(currentBook.book_name);
  document.getElementById('masahaLink').href = saved.masaha_url && saved.masaha_url.startsWith('http') ? saved.masaha_url : `https://www.masaha.org/book/${pId}`;
  document.getElementById('ablibraryLink').href = saved.ablibrary_url || `https://ablibrary.net/search?q=${qName}`;
  document.getElementById('alfekerLink').href = `https://alfeker.net/?s=${qName}`;
  document.getElementById('googlePdfLink').href = `https://www.google.com/search?q=${encodeURIComponent(currentBook.book_name + ' ' + (currentBook.authorName || '') + ' pdf')}`;

  currentOffset = saved.offset || 0;
  document.getElementById('offsetVal').textContent = currentOffset;

  // تعبئة قائمة الروابط المرشحة (Candidates)
  const candSel = document.getElementById('candidateSelect');
  candSel.innerHTML = '';
  const candidates = saved.candidates || [];
  if (candidates.length === 0 && saved.pdf_url) {
    candidates.push({ source: saved.pdf_source || 'الرابط الأساسي', url: saved.pdf_url });
  }
  candidates.forEach((c, i) => {
    const opt = document.createElement('option');
    opt.value = c.url;
    opt.textContent = `${i + 1}. ${c.source}`;
    if (c.url === saved.pdf_url) opt.selected = true;
    candSel.appendChild(opt);
  });

  const activeUrl = saved.pdf_url || (candidates[0] ? candidates[0].url : '');
  document.getElementById('pdfUrlInput').value = activeUrl;
  document.getElementById('pdfDirectLink').href = activeUrl || '#';

  // زر فتح الـ PDF المحلي إن تم تنزيله
  const localBtn = document.getElementById('openLocalPdfBtn');
  localBtn.style.display = saved.downloaded ? 'inline-flex' : 'none';

  const badge = document.getElementById('masahaStatusBadge');
  if (saved.downloaded) {
    badge.className = 'status-indicator status-has-pdf';
    badge.textContent = '📥 تم تنزيل الـ PDF في الجهاز';
  } else if (sc >= 90) {
    badge.className = 'status-indicator status-has-pdf';
    badge.textContent = `🟢 مطابق ممتاز (${sc}%)`;
  } else {
    badge.className = 'status-indicator status-no-pdf';
    badge.textContent = `⚠️ تحت 90% (${sc}% - تحقق وطابق)`;
  }

  updateSimilarityBadge(sc);

  // جلب نقاط الفحص الـ 5
  const res = await fetch(`${API_BASE}/api/book_part?book_id=${bId}&part_id=${pId}`);
  const data = await res.json();
  currentPartData = data;
  currentCheckpoints = data.checkpoints || [];
  
  renderTabs();
  selectTab(0);
}

function onCandidateSelectChange() {
  const url = document.getElementById('candidateSelect').value;
  if (url) {
    document.getElementById('pdfUrlInput').value = url;
    document.getElementById('pdfDirectLink').href = url;
    if (currentViewMode === 'pdf') {
      renderCandidateView();
    }
  }
}

function renderTabs() {
  const tabsBar = document.getElementById('tabsBar');
  tabsBar.innerHTML = '';
  currentCheckpoints.forEach((cp, idx) => {
    const btn = document.createElement('button');
    btn.className = `tab-btn ${idx === currentTabIdx ? 'active' : ''}`;
    btn.textContent = `${cp.label} (ص ${cp.source_page_id})`;
    btn.onclick = () => selectTab(idx);
    tabsBar.appendChild(btn);
  });
}

async function selectTab(idx) {
  currentTabIdx = idx;
  renderTabs();
  const cp = currentCheckpoints[idx];
  if (!cp) return;
  
  document.getElementById('sourceBody').innerHTML = `
    <div class="page-badge">❖ ترقيم المصدر الأصلي (DOCX): صفحة ${cp.source_page_id} ❖</div>
    <div>${cp.text}</div>
  `;
  document.getElementById('manualPageInput').value = cp.source_page_id;
  
  fetchAndRenderCandidate(cp.source_page_id);
}

async function fetchAndRenderCandidate(sourcePage) {
  const bId = currentBook.bookID;
  const pId = currentParts[currentPartIndex].partID;
  const saved = matchingState[`${bId}_${pId}`] || {};
  const abBookId = saved.ab_book_id || '';
  const targetPage = sourcePage + currentOffset;
  
  if (currentViewMode === 'pdf') {
    renderCandidateView();
    return;
  }

  document.getElementById('candidateBody').innerHTML = `
    <div style="text-align: center; color: #888; padding: 40px;">
      <p>⏳ جاري جلب الصفحة المقابلة (صفحة ${targetPage})...</p>
    </div>
  `;
  
  try {
    const res = await fetch(`${API_BASE}/api/masaha_page?part_id=${pId}&page_id=${targetPage}&ab_book_id=${encodeURIComponent(abBookId)}`);
    const data = await res.json();
    currentCandidateData = data;
    
    const sourceEl = document.getElementById('sourceBody');
    const sourceText = sourceEl.innerText;
    
    if (data.text) {
      const calcRes = await fetch(`${API_BASE}/api/calc_similarity`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ t1: sourceText, t2: data.text })
      });
      const calcData = await calcRes.json();
      currentCandidateData.score = calcData.score;
      updateSimilarityBadge(calcData.score);
    } else {
      currentCandidateData.score = parseFloat(saved.score) || 0;
    }
    
    renderCandidateView();
  } catch (e) {
    renderCandidateView();
  }
}

function setViewMode(mode) {
  currentViewMode = mode;
  document.getElementById('viewToggleScan').className = mode === 'scan' ? 'active' : '';
  document.getElementById('viewToggleText').className = mode === 'text' ? 'active' : '';
  document.getElementById('viewTogglePdf').className = mode === 'pdf' ? 'active' : '';
  renderCandidateView();
}

function renderCandidateView() {
  const body = document.getElementById('candidateBody');
  const targetPage = parseInt(document.getElementById('manualPageInput').value || '1') + currentOffset;
  const pdfUrl = document.getElementById('pdfUrlInput').value.trim();

  if (currentViewMode === 'pdf') {
    const bId = currentBook.bookID;
    const pId = currentParts[currentPartIndex].partID;
    const key = `${bId}_${pId}`;
    const saved = matchingState[key] || {};
    const iframeSrc = saved.downloaded ? `${API_BASE}/api/local_pdf?key=${key}#page=${targetPage}` : pdfUrl;
    body.innerHTML = `
      <div class="page-badge">❖ معاينة ملف الـ PDF المباشر (صفحة ${targetPage}) ❖</div>
      <iframe src="${iframeSrc}" style="width:100%; height:calc(100% - 45px); border:1px solid #ccc; border-radius:6px;"></iframe>
    `;
    return;
  }

  if (currentViewMode === 'scan' && currentCandidateData.image) {
    body.innerHTML = `
      <div class="page-badge">❖ صورة سكان الـ PDF المقابلة: صفحة ${targetPage} (الإزاحة: ${currentOffset}) ❖</div>
      <div class="scan-image-box">
        <img src="${currentCandidateData.image}" alt="Scan Page ${targetPage}">
      </div>
    `;
  } else {
    const txt = currentCandidateData.text || `
      <div style="font-family:'Cairo',sans-serif; background:#FFF8E7; border:1px solid #F0D995; padding:15px; border-radius:8px; font-size:0.95rem;">
        <p><strong>💡 لمعاينة ومطابقة هذا الكتاب مباشرة:</strong></p>
        <p style="margin-top:6px;">1. اضغط <strong>"📄 فتح ملف الـ DOCX في وورد"</strong> في الأعلى لفتح ملف الوورد الأصلي.</p>
        <p>2. اضغط <strong>"معاينة الـ PDF كامل"</strong> أو <strong>"📥 فتح رابط الـ PDF في نافذة جديدة"</strong> لمشاهدة الـ PDF.</p>
        <p>3. إن كان مطابقاً اضغط <strong>"📥 موافقة وتنزيل الـ PDF للجهاز"</strong>، وإن كان مختلفاً اضغط <strong>"❌ رفض / تجربة رابط ثاني"</strong>.</p>
      </div>`;
    body.innerHTML = `
      <div class="page-badge">❖ النص المقابل: صفحة ${targetPage} (الإزاحة: ${currentOffset}) ❖</div>
      <div style="font-family: 'Amiri', serif; font-size: 1.22rem; line-height: 2.05;">${txt}</div>
    `;
  }
}

function updateSimilarityBadge(score) {
  const box = document.getElementById('similarityBox');
  box.textContent = `نسبة التطابق: ${score}%`;
  if (score >= 90) box.className = 'similarity-badge score-high';
  else if (score >= 70) box.className = 'similarity-badge score-mid';
  else box.className = 'similarity-badge score-low';
}

function adjustOffset(delta) {
  currentOffset += delta;
  document.getElementById('offsetVal').textContent = currentOffset;
  const pNo = parseInt(document.getElementById('manualPageInput').value);
  fetchAndRenderCandidate(pNo);
}

async function loadManualPage() {
  const pNo = parseInt(document.getElementById('manualPageInput').value);
  if (!pNo) return;
  const pId = currentParts[currentPartIndex].partID;
  const res = await fetch(`${API_BASE}/api/page_text?part_id=${pId}&page_id=${pNo}`);
  const data = await res.json();
  document.getElementById('sourceBody').innerHTML = `
    <div class="page-badge">❖ ترقيم المصدر الأصلي: صفحة ${pNo} ❖</div>
    <div>${data.text || '<span style="color:red;">لا يوجد نص لهذه الصفحة في هذا المجلد</span>'}</div>
  `;
  fetchAndRenderCandidate(pNo);
}

function onManualPageChange() {
  loadManualPage();
}

function onPdfUrlChange() {
  const url = document.getElementById('pdfUrlInput').value.trim();
  document.getElementById('pdfDirectLink').href = url || '#';
}

async function openCurrentDocx() {
  const bId = currentBook.bookID;
  const pId = currentParts[currentPartIndex].partID;
  await fetch(`${API_BASE}/api/open_file?type=docx&key=${bId}_${pId}`);
}

async function openCurrentLocalPdf() {
  const bId = currentBook.bookID;
  const pId = currentParts[currentPartIndex].partID;
  await fetch(`${API_BASE}/api/open_file?type=pdf&key=${bId}_${pId}`);
}

async function openFolder(kind) {
  await fetch(`${API_BASE}/api/open_file?type=${kind}`);
}

async function approveAndDownload() {
  const bId = currentBook.bookID;
  const pId = currentParts[currentPartIndex].partID;
  const key = `${bId}_${pId}`;
  const pdfUrl = document.getElementById('pdfUrlInput').value.trim();
  if (!pdfUrl) {
    alert('الرجاء التأكد من وجود رابط PDF أولاً.');
    return;
  }

  const existing = matchingState[key] || {};
  existing.status = 'مطابق';
  existing.offset = currentOffset;
  existing.pdf_url = pdfUrl;
  existing.score = Math.max(parseFloat(existing.score) || 0, 95.0).toString();
  existing.downloaded = true;
  existing.notes = 'تم التحقق والاعتماد وتنزيل الـ PDF في الجهاز ✔️';
  matchingState[key] = existing;

  fetch(`${API_BASE}/api/approve_and_download`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key: key, pdf_url: pdfUrl, offset: currentOffset, entry: existing })
  });

  updateStats();
  nextPart();
}

async function approveOnly() {
  const bId = currentBook.bookID;
  const pId = currentParts[currentPartIndex].partID;
  const key = `${bId}_${pId}`;
  const pdfUrl = document.getElementById('pdfUrlInput').value.trim();

  const existing = matchingState[key] || {};
  existing.status = 'مطابق';
  existing.offset = currentOffset;
  existing.pdf_url = pdfUrl;
  existing.score = Math.max(parseFloat(existing.score) || 0, 92.0).toString();
  existing.notes = 'تم الاعتماد عبر استوديو المطابقة ✔️';
  matchingState[key] = existing;

  await fetch(`${API_BASE}/api/save_match`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(matchingState)
  });

  updateStats();
  nextPart();
}

async function rejectAndTryNext() {
  const bId = currentBook.bookID;
  const pId = currentParts[currentPartIndex].partID;
  const key = `${bId}_${pId}`;
  const candSel = document.getElementById('candidateSelect');

  // إذا كان هناك رابط بديل تالٍ في القائمة، انتقل إليه تلقائياً!
  if (candSel.options.length > 1 && candSel.selectedIndex < candSel.options.length - 1) {
    candSel.selectedIndex++;
    onCandidateSelectChange();
    const newUrl = candSel.value;
    window.open(newUrl, '_blank');
    return;
  }

  // إن لم يتبق رابط في القائمة، وسم كمرفوض وفتح البحث لاختيار رابط آخر
  const existing = matchingState[key] || {};
  existing.status = 'مرفوض - يحتاج رابط بديل';
  existing.score = '0';
  existing.notes = 'تم رفض الرابط الحالي - بانتظار وضع رابط بديل';
  matchingState[key] = existing;

  await fetch(`${API_BASE}/api/save_match`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(matchingState)
  });

  updateStats();
  window.open(document.getElementById('ablibraryLink').href, '_blank');
}

async function downloadAllAbove90() {
  if (!confirm('هل تريد بدء تنزيل جميع ملفات الـ PDF المعتمدة (فوق 90%) في الخلفية إلى مجلد كتب_المكتبة_PDF؟')) return;
  const res = await fetch(`${API_BASE}/api/download_batch_above90`, { method: 'POST' });
  const data = await res.json();
  alert(`تمت جدولة تنزيل ${data.queued} مجلد في الخلفية! يمكنك متابعة التقدم من الشريط العلوي.`);
}

function testCustomUrl() {
  const url = document.getElementById('pdfUrlInput').value.trim();
  if (url) window.open(url, '_blank');
}

async function exportToExcel() {
  const res = await fetch(`${API_BASE}/api/export_excel`);
  const data = await res.json();
  alert('تم تحديث وفتح ملف الإكسل الشامل بنجاح!\nالمسار: ' + data.path);
}

window.onload = init;
</script>

</body>
</html>
"""

_BOOKS_CACHE = None

def get_all_books_data():
    global _BOOKS_CACHE
    if _BOOKS_CACHE is not None:
        return _BOOKS_CACHE
    conn = sqlite3.connect(LIBRARY_DB)
    rows = conn.execute("SELECT bookID, book_name, authorName, category, cunt FROM Contents GROUP BY bookID ORDER BY bookID").fetchall()
    books = []
    for r in rows:
        b_id, name, author, cat_id, cunt = r
        parts = conn.execute("SELECT DISTINCT partID, joze FROM Contents WHERE bookID=? ORDER BY partID", (b_id,)).fetchall()
        part_list = []
        for idx, (p_id, jz) in enumerate(parts, 1):
            lbl = "الكتاب كامل" if len(parts) == 1 else (f"الجزء {jz}" if str(jz).isdigit() else (f"الجزء {idx}" if jz == '-' else str(jz)))
            part_list.append({"partID": p_id, "label": lbl, "raw_joze": jz})
        books.append({
            "bookID": b_id,
            "book_name": name,
            "authorName": author,
            "category": cat_id,
            "category_name": CATEGORY_FULL.get(cat_id, "عام"),
            "parts": part_list
        })
    conn.close()
    _BOOKS_CACHE = books
    return books

def render_studio_html():
    books_json = json.dumps(get_all_books_data(), ensure_ascii=False)
    state_json = json.dumps(load_matching_state(), ensure_ascii=False)
    return HTML_TEMPLATE.replace("__INITIAL_BOOKS__", books_json).replace("__INITIAL_STATE__", state_json)

# =============================================================================
# خادم الويب المحلي ومعالجة الطلبات البرمجية (REST API)
# =============================================================================
class MatcherRequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))

    def _send_html(self, html):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == '/' or path == '/index.html':
            self._send_html(render_studio_html())

        elif path == '/api/books':
            self._send_json(get_all_books_data())

        elif path == '/api/get_state':
            state = load_matching_state()
            self._send_json(state)

        elif path == '/api/download_status':
            self._send_json(DOWNLOAD_QUEUE_STATUS)

        elif path == '/api/book_part':
            p_id = int(qs.get('part_id', [0])[0])
            checkpoints = get_checkpoints_for_part(p_id)
            self._send_json({"partID": p_id, "checkpoints": checkpoints})

        elif path == '/api/page_text':
            p_id = int(qs.get('part_id', [0])[0])
            page_no = int(qs.get('page_id', [0])[0])
            txt = get_page_text(p_id, page_no)
            self._send_json({"partID": p_id, "page_id": page_no, "text": txt})

        elif path == '/api/masaha_page':
            p_id = int(qs.get('part_id', [0])[0])
            page_no = int(qs.get('page_id', [0])[0])
            ab_book_id = qs.get('ab_book_id', [''])[0]
            data = fetch_masaha_page(p_id, page_no, ab_book_id)
            self._send_json(data)

        elif path == '/api/local_pdf':
            key = qs.get('key', [''])[0]
            st = load_matching_state().get(key, {})
            p = st.get("local_pdf_path", "")
            if p and os.path.exists(p):
                self.send_response(200)
                self.send_header('Content-Type', 'application/pdf')
                self.end_headers()
                with open(p, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_error(404, "PDF Not Found Locally")

        elif path == '/api/open_file':
            kind = qs.get('type', [''])[0]
            key = qs.get('key', [''])[0]
            st = load_matching_state().get(key, {})
            target = ""
            if kind == 'docx':
                target = st.get("docx_path", "")
            elif kind == 'pdf':
                target = st.get("local_pdf_path", "")
            elif kind == 'pdf_dir':
                target = PDF_OUT_DIR
            if target and os.path.exists(target):
                try:
                    os.startfile(target)
                except Exception:
                    pass
                self._send_json({"status": "opened", "path": target})
            else:
                self._send_json({"status": "not_found", "path": target}, status=404)

        elif path == '/api/export_excel':
            state = load_matching_state()
            out_path = generate_excel_catalog(state)
            try:
                os.startfile(out_path)
            except Exception:
                pass
            self._send_json({"status": "ok", "path": out_path})

        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8') if length > 0 else "{}"

        if path == '/api/save_match':
            data = json.loads(body)
            save_matching_state(data)
            self._send_json({"status": "saved"})

        elif path == '/api/approve_and_download':
            payload = json.loads(body)
            key = payload.get("key")
            pdf_url = payload.get("pdf_url")
            entry = payload.get("entry")
            st = load_matching_state()
            if key and entry:
                st[key] = entry
                save_matching_state(st)
            if key and pdf_url:
                threading.Thread(target=download_pdf_worker, args=(key, pdf_url), daemon=True).start()
            self._send_json({"status": "queued", "key": key})

        elif path == '/api/download_batch_above90':
            st = load_matching_state()
            queued = 0
            def run_batch(items_to_dl):
                for k, u in items_to_dl:
                    download_pdf_worker(k, u)
            batch_list = []
            for k, v in st.items():
                sc = float(v.get("score", 0))
                if sc >= 90.0 and v.get("pdf_url") and not v.get("downloaded"):
                    batch_list.append((k, v["pdf_url"]))
            queued = len(batch_list)
            threading.Thread(target=run_batch, args=(batch_list,), daemon=True).start()
            self._send_json({"status": "started", "queued": queued})

        elif path == '/api/calc_similarity':
            payload = json.loads(body)
            t1 = payload.get('t1', '')
            t2 = payload.get('t2', '')
            score = calculate_similarity(t1, t2)
            self._send_json({"score": score})

        else:
            self.send_error(404, "Not Found")

def free_port_on_windows(port):
    my_pid = os.getpid()
    try:
        out = subprocess.check_output(f"netstat -ano | findstr :{port}", shell=True, text=True)
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 5 and "LISTENING" in line:
                pid = int(parts[-1])
                if pid != my_pid and pid > 0:
                    subprocess.run(f"taskkill /F /T /PID {pid}", shell=True, capture_output=True)
    except Exception:
        pass

def start_server(port=8500):
    free_port_on_windows(port)
    free_port_on_windows(8505)

    standalone_html = os.path.join(BASE_DIR, "استوديو_مطابقة_كتب_PDF.html")
    try:
        with open(standalone_html, "w", encoding="utf-8") as f:
            f.write(render_studio_html())
    except Exception:
        pass

    try:
        srv_alt = ThreadedHTTPServer(('127.0.0.1', 8505), MatcherRequestHandler)
        threading.Thread(target=srv_alt.serve_forever, daemon=True).start()
    except Exception:
        pass

    server = ThreadedHTTPServer(('127.0.0.1', port), MatcherRequestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()

if __name__ == '__main__':
    start_server(port=8500)
