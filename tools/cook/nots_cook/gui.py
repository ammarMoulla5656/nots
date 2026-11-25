"""واجهة رسومية (Tkinter GUI) لأداة طبخ الكتب (nots-cook).

تصميم مقسوم (جانبي: يمين / يسار) يضع إعدادات الكتاب والـ OCR في جانب،
ولوحة الديبغ والقراءة المباشرة (السجل الحي + النصوص المضافة + معاينة صور
فحص الصناديق) بكامل ارتفاع الشاشة في الجانب الآخر لسهولة القراءة والمراجعة.
"""

from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import pymupdf

from . import __version__, engines
from .cli import find_source

HERE = Path(__file__).resolve().parent
COOK_ROOT = HERE.parent


class CookApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(f'طبّاخ الكتب (nots-cook v{__version__}) — دمج PDF مع النص والـ OCR الذكي')
        self.root.geometry('1280x820')
        self.root.minsize(1020, 660)
        self.root.configure(bg='#F4F6F9')

        self.proc: subprocess.Popen | None = None
        self.is_running = False
        self.start_time = 0.0
        self.log_queue: queue.Queue[tuple[str, str]] = queue.Queue()
        self.last_out_pdf: Path | None = None
        self.last_report_path: Path | None = None
        self.last_debug_dir: Path | None = None
        self.last_added_file: Path | None = None

        self.debug_on_left = True  # الديبغ على اليسار والإعدادات على اليمين افتراضياً (مع زر للتبديل)
        self.log_font_size = 11
        self.debug_images_list: list[Path] = []
        self.debug_img_idx = 0
        self.debug_zoom = 1.0
        self._tk_img_ref = None

        self._init_vars()
        self._configure_styles()
        self._build_ui()
        self._probe_hardware_async()
        self._poll_queue()

    def _init_vars(self):
        cpu_total = os.cpu_count() or 4
        rec_workers = engines.default_workers()

        self.mode_var = tk.StringVar(value='file')  # 'file' | 'folder'
        self.pdf_var = tk.StringVar()
        self.text_var = tk.StringVar()
        self.no_text_var = tk.BooleanVar(value=False)
        self.out_var = tk.StringVar()
        self.title_var = tk.StringVar()

        # تحديد العدد / نطاق الصفحات
        self.page_scope_var = tk.StringVar(value='all')  # 'all' | 'first_n' | 'range' | 'custom'
        self.first_n_var = tk.IntVar(value=10)
        self.page_from_var = tk.IntVar(value=1)
        self.page_to_var = tk.IntVar(value=10)
        self.custom_pages_var = tk.StringVar(value='1-10')
        self.pdf_pages_info_var = tk.StringVar(value='لم يتم اختيار ملف PDF بعد')

        # الأداء والعتاد
        self.max_cores = cpu_total
        self.rec_workers = rec_workers
        self.workers_var = tk.IntVar(value=rec_workers)

        # إعدادات الـ OCR والدقة
        self.ocr_mode_var = tk.StringVar(value='auto')      # 'auto' | 'force' | 'off'
        self.strong_mode_var = tk.StringVar(value='auto')   # 'auto' | 'on' | 'off'
        self.check_var = tk.BooleanVar(value=True)
        self.keep_notes_var = tk.BooleanVar(value=False)
        self.clear_cache_var = tk.BooleanVar(value=False)
        self.debug_enable_var = tk.BooleanVar(value=True)
        self.debug_pages_var = tk.StringVar(value='1,2')

        # شريط الحالة والنتائج
        self.hw_status_var = tk.StringVar(value='جاري فحص المعالج وكرت الشاشة ومحركات الـ OCR ...')
        self.status_var = tk.StringVar(value='جاهز للبدء')
        self.elapsed_var = tk.StringVar(value='00:00')
        self.progress_var = tk.DoubleVar(value=0.0)
        self.summary_var = tk.StringVar(value='اختر ملف الكتاب (PDF) وملف النص من القائمة الجانبية ثم اضغط "ابدأ طبخ الكتاب".')
        self.dbg_page_label_var = tk.StringVar(value='لا توجد صور فحص حالياً')

    def _configure_styles(self):
        style = ttk.Style(self.root)
        try:
            style.theme_use('clam')
        except Exception:
            pass

        font_main = ('Segoe UI', 10)
        font_bold = ('Segoe UI', 10, 'bold')
        font_title = ('Segoe UI', 12, 'bold')

        style.configure('.', font=font_main, background='#F4F6F9', foreground='#1E293B')
        style.configure('TFrame', background='#F4F6F9')
        style.configure('Card.TLabelframe', background='#FFFFFF', foreground='#0F172A',
                        borderwidth=1, relief='solid')
        style.configure('Card.TLabelframe.Label', font=font_bold, background='#FFFFFF',
                        foreground='#1D4ED8', padding=(6, 2))
        style.configure('CardInner.TFrame', background='#FFFFFF')
        style.configure('Card.TLabel', background='#FFFFFF', foreground='#1E293B', font=font_main)
        style.configure('Muted.TLabel', background='#FFFFFF', foreground='#64748B', font=('Segoe UI', 9))
        style.configure('Banner.TLabel', background='#EFF6FF', foreground='#1E3A8A', font=font_bold, padding=6)
        style.configure('Header.TLabel', background='#1E293B', foreground='#FFFFFF', font=font_title)
        style.configure('SubHeader.TLabel', background='#1E293B', foreground='#94A3B8', font=('Segoe UI', 9))
        style.configure('Card.TRadiobutton', background='#FFFFFF', foreground='#1E293B', font=font_main)
        style.configure('Card.TCheckbutton', background='#FFFFFF', foreground='#1E293B', font=font_main)

        style.configure('Primary.TButton', font=('Segoe UI', 11, 'bold'),
                        background='#2563EB', foreground='#FFFFFF', padding=(14, 8))
        style.map('Primary.TButton',
                  background=[('active', '#1D4ED8'), ('disabled', '#94A3B8')],
                  foreground=[('disabled', '#E2E8F0')])

        style.configure('Danger.TButton', font=('Segoe UI', 10, 'bold'),
                        background='#DC2626', foreground='#FFFFFF', padding=(10, 7))
        style.map('Danger.TButton',
                  background=[('active', '#B91C1C'), ('disabled', '#FCA5A5')])

        style.configure('Action.TButton', font=('Segoe UI', 9, 'bold'),
                        background='#E2E8F0', foreground='#0F172A', padding=(7, 4))
        style.map('Action.TButton', background=[('active', '#CBD5E1')])

        style.configure('Gpu.TButton', font=('Segoe UI', 9, 'bold'),
                        background='#059669', foreground='#FFFFFF', padding=(8, 4))
        style.map('Gpu.TButton', background=[('active', '#047857')])

        style.configure('TNotebook', background='#F4F6F9')
        style.configure('TNotebook.Tab', font=('Segoe UI', 10, 'bold'), padding=(12, 6))
        style.configure('Green.Horizontal.TProgressbar',
                        troughcolor='#E2E8F0', background='#2563EB', thickness=16)

    def _build_ui(self):
        # 1. الشريط العلوي
        header = tk.Frame(self.root, bg='#1E293B', padx=14, pady=8)
        header.pack(fill='x')

        swap_btn = ttk.Button(
            header, text='⇄ تبديل موقع الديبغ (يمين / يسار)',
            style='Action.TButton', command=self._toggle_layout_side
        )
        swap_btn.pack(side='left', padx=4)

        title_box = tk.Frame(header, bg='#1E293B')
        title_box.pack(side='right')
        ttk.Label(title_box, text='طبّاخ الكتب (nots-cook) — واجهة التحكم والديبغ المباشر',
                  style='Header.TLabel').pack(anchor='e')
        ttk.Label(title_box, text='دمج ملفات الـ PDF مع الوورد/EPUB، تصحيح الخطوط، والـ OCR الهجين (CPU + NVIDIA RTX/GTX)',
                  style='SubHeader.TLabel').pack(anchor='e')

        # 2. شريط حالة العتاد
        hw_frame = tk.Frame(self.root, bg='#EFF6FF', highlightbackground='#BFDBFE', highlightthickness=1)
        hw_frame.pack(fill='x', padx=10, pady=(6, 4))
        self.gpu_btn = ttk.Button(hw_frame, text='⬇ تنزيل CUDA لكرت RTX',
                                  style='Gpu.TButton', command=self._install_cuda)
        ttk.Label(hw_frame, textvariable=self.hw_status_var, style='Banner.TLabel',
                  anchor='e', justify='right').pack(side='right', fill='x', expand=True)

        # 3. الحاوية المقسومة أفقياً (يمين / يسار)
        self.paned = ttk.PanedWindow(self.root, orient='horizontal')
        self.paned.pack(fill='both', expand=True, padx=10, pady=(2, 8))

        self.debug_panel = ttk.Frame(self.paned, padding=4)
        self.settings_panel = ttk.Frame(self.paned, padding=4)

        self._build_debug_panel(self.debug_panel)
        self._build_settings_panel(self.settings_panel)

        # ترتيب اللوحتين (الديبغ يسار والإعدادات يمين افتراضياً)
        self._apply_pane_order()

    def _apply_pane_order(self):
        for child in self.paned.panes():
            self.paned.forget(child)
        if self.debug_on_left:
            self.paned.add(self.debug_panel, weight=6)
            self.paned.add(self.settings_panel, weight=5)
        else:
            self.paned.add(self.settings_panel, weight=5)
            self.paned.add(self.debug_panel, weight=6)

    def _toggle_layout_side(self):
        self.debug_on_left = not self.debug_on_left
        self._apply_pane_order()

    # =========================================================================
    # جانب الديبغ والقراءة المباشرة (بكامل الارتفاع)
    # =========================================================================
    def _build_debug_panel(self, parent: ttk.Frame):
        dbg_card = ttk.LabelFrame(
            parent, text=' شاشة الديبغ والقراءة المباشرة (سجل العمليات + النصوص المضافة + صور الصناديق) ',
            style='Card.TLabelframe', padding=8
        )
        dbg_card.pack(fill='both', expand=True)

        # شريط الأدوات العلوي للديبغ
        toolbar = ttk.Frame(dbg_card, style='CardInner.TFrame')
        toolbar.pack(fill='x', pady=(0, 6))

        ttk.Button(toolbar, text='A+', width=3, style='Action.TButton',
                   command=lambda: self._change_font_size(1)).pack(side='left', padx=2)
        ttk.Button(toolbar, text='A-', width=3, style='Action.TButton',
                   command=lambda: self._change_font_size(-1)).pack(side='left', padx=2)
        ttk.Button(toolbar, text='📋 نسخ السجل', style='Action.TButton',
                   command=self._copy_log).pack(side='left', padx=3)
        ttk.Button(toolbar, text='🧹 مسح', style='Action.TButton',
                   command=self._clear_log).pack(side='left', padx=2)

        # أزرار فتح المخرجات السريعة
        self.open_pdf_btn = ttk.Button(toolbar, text='📄 فتح الكتاب',
                                       style='Action.TButton', command=self._open_out_pdf, state='disabled')
        self.open_pdf_btn.pack(side='right', padx=2)

        self.open_folder_btn = ttk.Button(toolbar, text='📁 المجلد',
                                          style='Action.TButton', command=self._open_out_folder, state='disabled')
        self.open_folder_btn.pack(side='right', padx=2)

        self.open_debug_btn = ttk.Button(toolbar, text='🖼 مجلد الصور',
                                         style='Action.TButton', command=self._open_debug_folder, state='disabled')
        self.open_debug_btn.pack(side='right', padx=2)

        self.open_added_btn = ttk.Button(toolbar, text='📝 ملف المضاف',
                                         style='Action.TButton', command=self._open_added_file, state='disabled')
        self.open_added_btn.pack(side='right', padx=2)

        # بطاقة ملخص النتيجة
        sum_bar = tk.Frame(dbg_card, bg='#F8FAFC', highlightbackground='#CBD5E1',
                           highlightthickness=1, padx=10, pady=6)
        sum_bar.pack(fill='x', pady=(0, 6))
        ttk.Label(sum_bar, textvariable=self.summary_var, background='#F8FAFC',
                  foreground='#0F172A', font=('Segoe UI', 10, 'bold'),
                  justify='right', wraplength=560).pack(anchor='e', fill='x')

        # التبويبات الثلاثة للقراءة المريحة بكامل طول النافذة
        self.notebook = ttk.Notebook(dbg_card)
        self.notebook.pack(fill='both', expand=True)

        # تبويب 1: سجل الديبغ المباشر
        tab_log = ttk.Frame(self.notebook, style='CardInner.TFrame')
        self.notebook.add(tab_log, text='  🖥 سجل الديبغ المباشر (Live Log)  ')

        log_scroll_y = ttk.Scrollbar(tab_log, orient='vertical')
        log_scroll_y.pack(side='right', fill='y')
        log_scroll_x = ttk.Scrollbar(tab_log, orient='horizontal')
        log_scroll_x.pack(side='bottom', fill='x')

        self.log_text = tk.Text(
            tab_log, bg='#0F172A', fg='#E2E8F0',
            insertbackground='#FFFFFF', font=('Consolas', self.log_font_size),
            yscrollcommand=log_scroll_y.set, xscrollcommand=log_scroll_x.set,
            wrap='word', padx=12, pady=10, state='disabled'
        )
        self.log_text.pack(side='left', fill='both', expand=True)
        log_scroll_y.config(command=self.log_text.yview)
        log_scroll_x.config(command=self.log_text.xview)

        self._update_text_tags()

        # تبويب 2: قراءة النصوص المضافة وتقرير التطابق
        tab_added = ttk.Frame(self.notebook, style='CardInner.TFrame')
        self.notebook.add(tab_added, text='  📊 تقرير التطابق والنصوص المضافة  ')

        added_scroll = ttk.Scrollbar(tab_added, orient='vertical')
        added_scroll.pack(side='right', fill='y')
        self.added_text = tk.Text(
            tab_added, bg='#FFFFFF', fg='#0F172A',
            font=('Segoe UI', self.log_font_size),
            yscrollcommand=added_scroll.set, wrap='word', padx=14, pady=10, state='disabled'
        )
        self.added_text.pack(side='left', fill='both', expand=True)
        added_scroll.config(command=self.added_text.yview)

        # تبويب 3: معاينة صور فحص الصناديق (Debug PNGs) داخل البرنامج
        tab_img = ttk.Frame(self.notebook, style='CardInner.TFrame')
        self.notebook.add(tab_img, text='  🔍 معاينة صور الصناديق (Debug Pages)  ')

        img_bar = ttk.Frame(tab_img, style='CardInner.TFrame', padding=4)
        img_bar.pack(fill='x')
        ttk.Button(img_bar, text='◀ السابقة', style='Action.TButton',
                   command=lambda: self._step_debug_image(-1)).pack(side='right', padx=3)
        ttk.Button(img_bar, text='التالية ▶', style='Action.TButton',
                   command=lambda: self._step_debug_image(1)).pack(side='right', padx=3)
        ttk.Button(img_bar, text='تكبير +', style='Action.TButton',
                   command=lambda: self._zoom_debug_image(1.2)).pack(side='left', padx=3)
        ttk.Button(img_bar, text='تصغير -', style='Action.TButton',
                   command=lambda: self._zoom_debug_image(1 / 1.2)).pack(side='left', padx=3)
        ttk.Button(img_bar, text='100%', style='Action.TButton',
                   command=lambda: self._zoom_debug_image(0.0)).pack(side='left', padx=3)
        ttk.Label(img_bar, textvariable=self.dbg_page_label_var,
                  style='Card.TLabel', font=('Segoe UI', 9, 'bold')).pack(side='right', padx=10)

        canvas_frame = ttk.Frame(tab_img, style='CardInner.TFrame')
        canvas_frame.pack(fill='both', expand=True)
        vbar = ttk.Scrollbar(canvas_frame, orient='vertical')
        vbar.pack(side='right', fill='y')
        hbar = ttk.Scrollbar(canvas_frame, orient='horizontal')
        hbar.pack(side='bottom', fill='x')

        self.img_canvas = tk.Canvas(canvas_frame, bg='#1E293B', highlightthickness=0,
                                    yscrollcommand=vbar.set, xscrollcommand=hbar.set)
        self.img_canvas.pack(side='left', fill='both', expand=True)
        vbar.config(command=self.img_canvas.yview)
        hbar.config(command=self.img_canvas.xview)

    def _update_text_tags(self):
        f_reg = ('Consolas', self.log_font_size)
        f_bold = ('Consolas', self.log_font_size, 'bold')
        self.log_text.configure(font=f_reg)
        self.log_text.tag_config('info', foreground='#E2E8F0', font=f_reg)
        self.log_text.tag_config('good', foreground='#4ADE80', font=f_bold)
        self.log_text.tag_config('warn', foreground='#FACC15', font=f_reg)
        self.log_text.tag_config('err', foreground='#F87171', font=f_bold)
        self.log_text.tag_config('cmd', foreground='#38BDF8', font=f_reg)
        if hasattr(self, 'added_text'):
            self.added_text.configure(font=('Segoe UI', self.log_font_size))

    def _change_font_size(self, delta: int):
        self.log_font_size = max(8, min(22, self.log_font_size + delta))
        self._update_text_tags()

    def _copy_log(self):
        content = self.log_text.get('1.0', 'end-1c')
        self.root.clipboard_clear()
        self.root.clipboard_append(content)
        self.status_var.set('تم نسخ السجل إلى الحافظة')

    # =========================================================================
    # جانب الإعدادات والتحكم
    # =========================================================================
    def _build_settings_panel(self, parent: ttk.Frame):
        # 1. قسم الملفات
        files_card = ttk.LabelFrame(parent, text=' 1. ملفات الكتاب والنص والإخراج ',
                                    style='Card.TLabelframe', padding=10)
        files_card.pack(fill='x', pady=(0, 6))
        files_card.columnconfigure(1, weight=1)

        mode_row = ttk.Frame(files_card, style='CardInner.TFrame')
        mode_row.grid(row=0, column=0, columnspan=3, sticky='ew', pady=(0, 6))
        ttk.Radiobutton(mode_row, text='ملف كتاب واحد (PDF)', value='file',
                        variable=self.mode_var, style='Card.TRadiobutton',
                        command=self._on_mode_change).pack(side='right', padx=4)
        ttk.Radiobutton(mode_row, text='مجلد كتب كامل', value='folder',
                        variable=self.mode_var, style='Card.TRadiobutton',
                        command=self._on_mode_change).pack(side='right', padx=4)
        ttk.Label(mode_row, textvariable=self.pdf_pages_info_var,
                  style='Muted.TLabel').pack(side='left', padx=4)

        ttk.Button(files_card, text='استعراض PDF...', style='Action.TButton',
                   command=self._browse_pdf).grid(row=1, column=0, padx=(0, 6), pady=3, sticky='ew')
        self.pdf_entry = ttk.Entry(files_card, textvariable=self.pdf_var, justify='left')
        self.pdf_entry.grid(row=1, column=1, pady=3, sticky='ew')
        ttk.Label(files_card, text=':الكتاب (PDF)', style='Card.TLabel').grid(
            row=1, column=2, padx=(6, 0), pady=3, sticky='e')

        self.text_browse_btn = ttk.Button(files_card, text='استعراض النص...', style='Action.TButton',
                                          command=self._browse_text)
        self.text_browse_btn.grid(row=2, column=0, padx=(0, 6), pady=3, sticky='ew')
        self.text_entry = ttk.Entry(files_card, textvariable=self.text_var, justify='left')
        self.text_entry.grid(row=2, column=1, pady=3, sticky='ew')
        ttk.Label(files_card, text=':ملف النص', style='Card.TLabel').grid(
            row=2, column=2, padx=(6, 0), pady=3, sticky='e')

        ttk.Button(files_card, text='مكان الحفظ...', style='Action.TButton',
                   command=self._browse_out).grid(row=3, column=0, padx=(0, 6), pady=3, sticky='ew')
        self.out_entry = ttk.Entry(files_card, textvariable=self.out_var, justify='left')
        self.out_entry.grid(row=3, column=1, pady=3, sticky='ew')
        ttk.Label(files_card, text=':ملف الإخراج', style='Card.TLabel').grid(
            row=3, column=2, padx=(6, 0), pady=3, sticky='e')

        extra_file_row = ttk.Frame(files_card, style='CardInner.TFrame')
        extra_file_row.grid(row=4, column=0, columnspan=3, sticky='ew', pady=(4, 0))
        ttk.Label(extra_file_row, text='عنوان الكتاب:', style='Card.TLabel').pack(side='right', padx=(4, 0))
        ttk.Entry(extra_file_row, textvariable=self.title_var, justify='right', width=24).pack(
            side='right', padx=6, fill='x', expand=True)
        ttk.Checkbutton(extra_file_row, text='بدون ملف نص (PDF فقط)', variable=self.no_text_var,
                        style='Card.TCheckbutton', command=self._on_no_text_toggle).pack(side='left', padx=4)

        # 2. قسم تحديد العدد ونطاق الصفحات
        pages_card = ttk.LabelFrame(parent, text=' 2. تحديد العدد ونطاق الصفحات ',
                                    style='Card.TLabelframe', padding=10)
        pages_card.pack(fill='x', pady=(0, 6))

        r_all = ttk.Frame(pages_card, style='CardInner.TFrame')
        r_all.pack(fill='x', pady=2)
        ttk.Radiobutton(r_all, text='كل صفحات الكتاب بالكامل', value='all',
                        variable=self.page_scope_var, style='Card.TRadiobutton',
                        command=self._update_out_filename).pack(side='right')

        r_first = ttk.Frame(pages_card, style='CardInner.TFrame')
        r_first.pack(fill='x', pady=2)
        ttk.Radiobutton(r_first, text='أول عدد صفحات (تجربة):', value='first_n',
                        variable=self.page_scope_var, style='Card.TRadiobutton',
                        command=self._update_out_filename).pack(side='right')
        ttk.Spinbox(r_first, from_=1, to=5000, textvariable=self.first_n_var, width=6,
                    command=self._update_out_filename).pack(side='right', padx=4)
        for preset in (2, 5, 10, 25):
            ttk.Button(r_first, text=f'{preset} ص', style='Action.TButton', width=4,
                       command=lambda p=preset: self._set_first_n(p)).pack(side='right', padx=2)

        r_range = ttk.Frame(pages_card, style='CardInner.TFrame')
        r_range.pack(fill='x', pady=2)
        ttk.Radiobutton(r_range, text='نطاق من صفحة:', value='range',
                        variable=self.page_scope_var, style='Card.TRadiobutton',
                        command=self._update_out_filename).pack(side='right')
        ttk.Spinbox(r_range, from_=1, to=5000, textvariable=self.page_from_var, width=6).pack(side='right', padx=4)
        ttk.Label(r_range, text='إلى صفحة:', style='Card.TLabel').pack(side='right', padx=2)
        ttk.Spinbox(r_range, from_=1, to=5000, textvariable=self.page_to_var, width=6).pack(side='right', padx=4)

        r_custom = ttk.Frame(pages_card, style='CardInner.TFrame')
        r_custom.pack(fill='x', pady=2)
        ttk.Radiobutton(r_custom, text='أرقام صفحات مخصصة (مثل 124,774):', value='custom',
                        variable=self.page_scope_var, style='Card.TRadiobutton',
                        command=self._update_out_filename).pack(side='right')
        ttk.Entry(r_custom, textvariable=self.custom_pages_var, width=16, justify='left').pack(side='right', padx=6)

        # 3. قسم عدد الأنوية وقوة المعالج والذاكرة التراتبية
        perf_card = ttk.LabelFrame(
            parent,
            text=' 3. القوة القصوى (100% CPU + 100% GPU) والذاكرة التراتبية (C: SSD ⇄ RAM ⇄ VRAM) ',
            style='Card.TLabelframe', padding=10
        )
        perf_card.pack(fill='x', pady=(0, 6))

        w_top = ttk.Frame(perf_card, style='CardInner.TFrame')
        w_top.pack(fill='x', pady=2)
        ttk.Label(w_top, text='عدد أنوية المعالج المتوازية (CPU Workers بالتوازي مع GPU):',
                  style='Card.TLabel', font=('Segoe UI', 9, 'bold')).pack(side='right')
        self.workers_lbl = ttk.Label(w_top, text=f'{self.workers_var.get()} / {self.max_cores}',
                                     style='Card.TLabel', font=('Segoe UI', 10, 'bold'))
        self.workers_lbl.pack(side='left', padx=6)

        self.workers_scale = ttk.Scale(
            perf_card, from_=1, to=self.max_cores, orient='horizontal',
            command=self._on_workers_slide)
        self.workers_scale.set(self.workers_var.get())
        self.workers_scale.pack(fill='x', padx=4, pady=4)

        w_btns = ttk.Frame(perf_card, style='CardInner.TFrame')
        w_btns.pack(fill='x', pady=2)
        ttk.Button(w_btns, text=f'🔥 أقصى قوة 100% ({self.max_cores} أنوية + GPU - الافتراضي)',
                   style='Action.TButton',
                   command=lambda: self._set_workers(self.max_cores)).pack(side='right', padx=2)
        ttk.Button(w_btns, text=f'متوازن ({max(2, self.max_cores - 4)})',
                   style='Action.TButton',
                   command=lambda: self._set_workers(max(2, self.max_cores - 4))).pack(side='right', padx=2)
        ttk.Button(w_btns, text=f'هادئ ({max(2, self.max_cores // 2)})',
                   style='Action.TButton',
                   command=lambda: self._set_workers(max(2, self.max_cores // 2))).pack(side='right', padx=2)

        # 4. قسم إعدادات الـ OCR و Qari والفحص
        opts_card = ttk.LabelFrame(parent, text=' 4. إعدادات الـ OCR ونموذج الذكاء الاصطناعي والفحص ',
                                   style='Card.TLabelframe', padding=10)
        opts_card.pack(fill='x', pady=(0, 6))

        ttk.Label(opts_card, text='وضع الـ OCR الأساسي:', style='Card.TLabel',
                  font=('Segoe UI', 9, 'bold')).pack(anchor='e')
        row_ocr = ttk.Frame(opts_card, style='CardInner.TFrame')
        row_ocr.pack(fill='x', pady=(2, 6))
        ttk.Radiobutton(row_ocr, text='تلقائي هجين ذكي (auto - موصى به)',
                        value='auto', variable=self.ocr_mode_var, style='Card.TRadiobutton').pack(side='right', padx=4)
        ttk.Radiobutton(row_ocr, text='إجباري كامل (force)',
                        value='force', variable=self.ocr_mode_var, style='Card.TRadiobutton').pack(side='right', padx=4)
        ttk.Radiobutton(row_ocr, text='إيقاف (off)',
                        value='off', variable=self.ocr_mode_var, style='Card.TRadiobutton').pack(side='right', padx=4)

        ttk.Label(opts_card, text='نموذج الرؤية العميق للحواشي (Qari-OCR على كرت الشاشة RTX/GTX):',
                  style='Card.TLabel', font=('Segoe UI', 9, 'bold')).pack(anchor='e')
        row_strong = ttk.Frame(opts_card, style='CardInner.TFrame')
        row_strong.pack(fill='x', pady=(2, 6))
        ttk.Radiobutton(row_strong, text='تلقائي مع GPU (auto)',
                        value='auto', variable=self.strong_mode_var, style='Card.TRadiobutton').pack(side='right', padx=4)
        ttk.Radiobutton(row_strong, text='تشغيل دائماً (on)',
                        value='on', variable=self.strong_mode_var, style='Card.TRadiobutton').pack(side='right', padx=4)
        ttk.Radiobutton(row_strong, text='إيقاف للتسريع (off)',
                        value='off', variable=self.strong_mode_var, style='Card.TRadiobutton').pack(side='right', padx=4)

        ttk.Checkbutton(opts_card, text='فحص جودة الملف وتطابق البكسلات بعد الطبخ (موصى به)',
                        variable=self.check_var, style='Card.TCheckbutton').pack(anchor='e', pady=1)
        ttk.Checkbutton(opts_card, text='الاحتفاظ بالحواشي التحريرية مثل [مطابق للأصل]',
                        variable=self.keep_notes_var, style='Card.TCheckbutton').pack(anchor='e', pady=1)
        ttk.Checkbutton(opts_card, text='مسح كاش الـ OCR السابق (.ocr.json) وإعادة القراءة من الصفر',
                        variable=self.clear_cache_var, style='Card.TCheckbutton').pack(anchor='e', pady=1)

        row_dbg = ttk.Frame(opts_card, style='CardInner.TFrame')
        row_dbg.pack(fill='x', pady=(4, 0))
        ttk.Checkbutton(row_dbg, text='رسم صور فحص الصناديق (Debug Pages) للصفحات:',
                        variable=self.debug_enable_var, style='Card.TCheckbutton').pack(side='right')
        ttk.Entry(row_dbg, textvariable=self.debug_pages_var, width=12, justify='left').pack(side='right', padx=6)

        # 5. أزرار التشغيل وشريط التقدم
        ctrl_card = ttk.Frame(parent)
        ctrl_card.pack(fill='x', pady=(4, 0))

        btn_row = ttk.Frame(ctrl_card)
        btn_row.pack(fill='x', pady=(0, 6))
        self.run_btn = ttk.Button(btn_row, text='▶  ابدأ طبخ الكتاب الآن',
                                  style='Primary.TButton', command=self.start_cook)
        self.run_btn.pack(side='right', fill='x', expand=True, padx=(4, 0))

        self.stop_btn = ttk.Button(btn_row, text='⏹ إيقاف',
                                   style='Danger.TButton', command=self.stop_cook, state='disabled')
        self.stop_btn.pack(side='left', padx=(0, 4))

        prog_row = ttk.Frame(ctrl_card)
        prog_row.pack(fill='x')
        ttk.Label(prog_row, textvariable=self.elapsed_var,
                  font=('Consolas', 10, 'bold'), foreground='#1D4ED8').pack(side='left', padx=(0, 6))
        self.prog_bar = ttk.Progressbar(prog_row, variable=self.progress_var,
                                        maximum=100.0, style='Green.Horizontal.TProgressbar')
        self.prog_bar.pack(side='left', fill='x', expand=True)

        ttk.Label(ctrl_card, textvariable=self.status_var,
                  font=('Segoe UI', 9, 'bold'), foreground='#0F172A').pack(anchor='e', pady=(4, 0))

    # ---- فحص العتاد وكرت الشاشة ----

    def _probe_hardware_async(self):
        def worker():
            tess = engines.find_tesseract()
            win_lang = engines.windows_ocr_language()
            gpu = engines.nvidia_gpu_info()
            ram = engines.system_ram_info()
            qari = engines.find_qari()

            parts = [f'المعالج: {self.max_cores} أنوية (100% أقصى قوة)']
            if gpu:
                parts.append(f'كرت الشاشة: {gpu["name"]} ({gpu["vram_mb"]} MB VRAM)')
            else:
                parts.append('كرت الشاشة: غير متوفر (CPU فقط)')
            parts.append(f'الذاكرة التراتبية: C: SSD ⇄ RAM ({ram["total_mb"] // 1024} GB) ⇄ VRAM')

            ocr_parts = []
            if tess:
                ocr_parts.append('Tesseract 5')
            if win_lang:
                ocr_parts.append(f'Windows OCR ({win_lang})')
            if qari:
                q_py, q_dev = qari.rsplit('|', 1)
                ocr_parts.append(f'Qari-VL ({q_dev.upper()} 100%)')
            if gpu and not (qari and qari.endswith('|gpu')):
                self.root.after(0, lambda: self.gpu_btn.pack(side='left', padx=8, pady=4))
            parts.append('المحركات: ' + (' + '.join(ocr_parts) if ocr_parts else 'غير متوفرة'))
            msg = '  |  '.join(parts)
            self.root.after(0, lambda: self.hw_status_var.set(msg))

        threading.Thread(target=worker, daemon=True).start()

    def _install_cuda(self):
        if self.is_running:
            return
        if not messagebox.askyesno(
            'تنزيل CUDA لكرت الشاشة NVIDIA',
            'سيتم تجهيز كرت الشاشة لقراءة Qari: بيئة Python خاصة، وPyTorch مع CUDA (نحو 3 GB)، '
            'ونموذج Qari (نحو 4.5 GB).\n'
            'يحتاج اتصالاً بالإنترنت و20 GB مساحة حرة، وقد يستغرق وقتاً. هل تريد المتابعة؟'
        ):
            return
        cmd = [sys.executable, '-X', 'utf8', '-u', str(HERE / 'setup_gpu.py')]
        self.status_var.set('جاري تنزيل CUDA ونموذج Qari ... تابع السجل')
        self.gpu_btn.config(state='disabled')

        def run_setup():
            try:
                p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     encoding='utf-8', errors='replace',
                                     creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                for line in p.stdout:
                    self.log_queue.put((line, 'info'))
                rc = p.wait()
            except Exception as e:
                self.log_queue.put((f'\n✗ خطأ: {e}\n', 'err'))
                rc = 1
            if rc == 0:
                engines._QARI_CACHE = (False, None)
                self.log_queue.put(('\n✓ تم تجهيز كرت الشاشة بنجاح!\n', 'good'))
                self.root.after(0, self.gpu_btn.pack_forget)
                self._probe_hardware_async()
            else:
                self.log_queue.put((f'\n✗ فشل التجهيز (رمز الخروج {rc}): راجع السجل أعلاه\n', 'err'))
            self.root.after(0, lambda: (self.gpu_btn.config(state='normal'), self.status_var.set('جاهز')))

        threading.Thread(target=run_setup, daemon=True).start()

    # ---- أحداث الواجهة واختيار الملفات ----

    def _on_mode_change(self):
        is_folder = self.mode_var.get() == 'folder'
        state = 'disabled' if is_folder else 'normal'
        self.text_entry.config(state='disabled' if (is_folder or self.no_text_var.get()) else 'normal')
        self.text_browse_btn.config(state='disabled' if (is_folder or self.no_text_var.get()) else 'normal')
        self.out_entry.config(state=state)

    def _on_no_text_toggle(self):
        disabled = self.no_text_var.get() or self.mode_var.get() == 'folder'
        self.text_entry.config(state='disabled' if disabled else 'normal')
        self.text_browse_btn.config(state='disabled' if disabled else 'normal')

    def _on_workers_slide(self, val):
        v = max(1, int(float(val)))
        self.workers_var.set(v)
        self.workers_lbl.config(text=f'{v} / {self.max_cores}')

    def _set_workers(self, n: int):
        self.workers_var.set(n)
        self.workers_scale.set(n)
        self.workers_lbl.config(text=f'{n} / {self.max_cores}')

    def _set_first_n(self, n: int):
        self.page_scope_var.set('first_n')
        self.first_n_var.set(n)
        self._update_out_filename()

    def _browse_pdf(self):
        if self.mode_var.get() == 'folder':
            folder = filedialog.askdirectory(title='اختر مجلد الكتب')
            if folder:
                self.pdf_var.set(folder)
                pdfs = [x for x in Path(folder).glob('*.pdf') if not x.name.endswith('.nots.pdf')]
                self.pdf_pages_info_var.set(f'المجلد يحتوي {len(pdfs)} ملف PDF')
            return

        path = filedialog.askopenfilename(
            title='اختر ملف الكتاب (PDF)',
            filetypes=[('PDF Files', '*.pdf'), ('All Files', '*.*')]
        )
        if path:
            self._open_pdf(Path(path))

    def open_book(self, path: Path):
        """Opens the PDF at [path], or the first book in the folder at [path]."""
        if path.is_dir():
            path = next((x for x in sorted(path.glob('*.pdf')) if not x.name.endswith('.nots.pdf')), None)
        if path:
            self._open_pdf(path)

    def _open_pdf(self, p: Path):
        self.pdf_var.set(str(p))
        try:
            doc = pymupdf.open(p)
            n_pages = doc.page_count
            title = (doc.metadata or {}).get('title') or p.stem
            doc.close()
            self.page_to_var.set(min(10, n_pages))
            cache_exists = (p.with_name(p.stem + '.nots.ocr.json').exists()
                            or p.with_name(p.stem + '.ocr.json').exists())
            cache_tag = ' (يوجد كاش OCR)' if cache_exists else ''
            self.pdf_pages_info_var.set(f'{n_pages} صفحة{cache_tag}')
            if not self.title_var.get():
                self.title_var.set(title)
        except Exception:
            self.pdf_pages_info_var.set('تعذّر قراءة عدد الصفحات')

        src = find_source(p)
        if src:
            self.text_var.set(str(src))
            self.no_text_var.set(False)
            self._on_no_text_toggle()
        self._update_out_filename()
        if self.out_var.get().strip():
            cand_out = Path(self.out_var.get().strip())
            if cand_out.exists():
                self.last_out_pdf = cand_out
                self._load_and_show_report()

    def _browse_text(self):
        path = filedialog.askopenfilename(
            title='اختر ملف النص المصدري (Word / EPUB / TXT)',
            filetypes=[('ملفات النص', '*.docx *.epub *.txt'),
                       ('Word (.docx)', '*.docx'),
                       ('EPUB (.epub)', '*.epub'),
                       ('Text (.txt)', '*.txt'),
                       ('All Files', '*.*')]
        )
        if path:
            self.text_var.set(path)

    def _browse_out(self):
        path = filedialog.asksaveasfilename(
            title='حفظ الكتاب المطبوخ باسم',
            defaultextension='.nots.pdf',
            filetypes=[('Nots PDF', '*.nots.pdf'), ('PDF', '*.pdf')]
        )
        if path:
            self.out_var.set(path)

    def _update_out_filename(self):
        if self.mode_var.get() == 'folder':
            return
        pdf_str = self.pdf_var.get().strip()
        if not pdf_str:
            return
        p = Path(pdf_str)
        is_trial = self.page_scope_var.get() != 'all'
        suffix = '.trial.nots.pdf' if is_trial else '.nots.pdf'
        stem = re.sub(r'(\.trial)?\.nots$', '', p.stem)
        self.out_var.set(str(p.with_name(stem + suffix)))

    def _get_pages_arg(self) -> str | None:
        scope = self.page_scope_var.get()
        if scope == 'all':
            return None
        if scope == 'first_n':
            n = max(1, int(self.first_n_var.get()))
            return f'1-{n}'
        if scope == 'range':
            a = max(1, int(self.page_from_var.get()))
            b = max(a, int(self.page_to_var.get()))
            return f'{a}-{b}'
        if scope == 'custom':
            s = self.custom_pages_var.get().strip()
            return s or None
        return None

    # ---- تشغيل وإيقاف عملية الطبخ ----

    def start_cook(self):
        if self.is_running:
            return
        pdf_str = self.pdf_var.get().strip()
        if not pdf_str or not Path(pdf_str).exists():
            messagebox.showwarning('تنبيه', 'يرجى اختيار ملف الكتاب (PDF) أو مجلد الكتب أولاً.')
            return

        p_pdf = Path(pdf_str)
        if self.clear_cache_var.get() and p_pdf.is_file():
            cache_files = [
                c for c in (p_pdf.with_name(p_pdf.stem + '.nots.ocr.json'),
                            p_pdf.with_name(p_pdf.stem + '.ocr.json'))
                if c.exists()
            ]
            if self.out_var.get().strip():
                out_c = Path(self.out_var.get().strip())
                out_c = out_c.with_name(out_c.stem + '.ocr.json')
                if out_c.exists() and out_c not in cache_files:
                    cache_files.append(out_c)
            if cache_files:
                size_mb = sum(c.stat().st_size for c in cache_files) / (1024 * 1024)
                if messagebox.askyesno(
                    'تأكيد مسح كاش الـ OCR',
                    f'يوجد كاش OCR محفوظ بحجم {size_mb:.1f} MB.\n'
                    'هل تريد حقاً مسحه وإعادة قراءة الصفحات من الصفر؟\n'
                    '(اختر "لا" لاستكمال الطبخ فوراً من الكاش المحفوظ خلال ثوانٍ)'
                ):
                    for c_file in cache_files:
                        c_file.unlink(missing_ok=True)
            self.clear_cache_var.set(False)

        cmd = [sys.executable, '-X', 'utf8', '-u', str(COOK_ROOT / 'cook.py'), str(p_pdf)]

        if self.mode_var.get() == 'file':
            if self.no_text_var.get():
                cmd.append('--no-text')
            elif self.text_var.get().strip():
                t_path = Path(self.text_var.get().strip())
                if not t_path.exists():
                    messagebox.showwarning('تنبيه', f'ملف النص المحدد غير موجود:\n{t_path}')
                    return
                cmd += ['--text', str(t_path)]

            out_str = self.out_var.get().strip()
            if out_str:
                cmd += ['-o', out_str]
                self.last_out_pdf = Path(out_str)
            else:
                self.last_out_pdf = p_pdf.with_name(p_pdf.stem + '.nots.pdf')

            if self.title_var.get().strip():
                cmd += ['--title', self.title_var.get().strip()]

            pages_arg = self._get_pages_arg()
            if pages_arg:
                cmd += ['--pages', pages_arg]

        cmd += ['--ocr', self.ocr_mode_var.get()]
        cmd += ['--strong', self.strong_mode_var.get()]
        cmd += ['--workers', str(self.workers_var.get())]

        if not self.check_var.get():
            cmd.append('--no-check')
        if self.keep_notes_var.get():
            cmd.append('--keep-notes')
        if self.debug_enable_var.get() and self.debug_pages_var.get().strip():
            cmd += ['--debug-pages', self.debug_pages_var.get().strip()]

        self.is_running = True
        self.start_time = time.time()
        self.progress_var.set(2.0)
        self.status_var.set('جاري تشغيل طبّاخ الكتب ...')
        self.summary_var.set('العملية قيد التنفيذ — تابع التفاصيل الحية في سجل الديبغ أدناه ...')
        self.run_btn.config(state='disabled')
        self.stop_btn.config(state='normal')
        for b in (self.open_pdf_btn, self.open_folder_btn, self.open_debug_btn, self.open_added_btn):
            b.config(state='disabled')

        self.notebook.select(0)
        self._clear_log()
        self._append_log(f'$ {" ".join(cmd)}\n\n', 'cmd')

        def run_worker():
            flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000) if sys.platform == 'win32' else 0
            try:
                self.proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding='utf-8', errors='replace',
                    cwd=str(COOK_ROOT.parent), creationflags=flags
                )
                for line in self.proc.stdout:
                    self.log_queue.put((line, 'line'))
                rc = self.proc.wait()
                self.log_queue.put((str(rc), 'done'))
            except Exception as e:
                self.log_queue.put((f'\nخطأ أثناء التشغيل: {e}\n', 'err'))
                self.log_queue.put(('-1', 'done'))

        threading.Thread(target=run_worker, daemon=True).start()

    def stop_cook(self):
        if not self.is_running or not self.proc:
            return
        try:
            if sys.platform == 'win32':
                subprocess.run(['taskkill', '/F', '/T', '/PID', str(self.proc.pid)],
                               capture_output=True, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            else:
                self.proc.terminate()
        except Exception:
            pass
        self.log_queue.put(('\n⚠ تم إيقاف العملية بواسطة المستخدم.\n', 'warn'))

    # ---- معالجة السجل الحي والتقدم ----

    def _poll_queue(self):
        if self.is_running:
            elapsed = int(time.time() - self.start_time)
            mins, secs = divmod(elapsed, 60)
            self.elapsed_var.set(f'{mins:02d}:{secs:02d}')

        try:
            while True:
                msg, kind = self.log_queue.get_nowait()
                if kind == 'line':
                    self._handle_process_line(msg)
                elif kind == 'done':
                    self._on_process_done(int(msg))
                else:
                    self._append_log(msg, kind)
        except queue.Empty:
            pass

        self.root.after(150, self._poll_queue)

    def _handle_process_line(self, line: str):
        tag = 'info'
        s = line.strip()
        if (s.startswith('==') or 'written ' in s or 'done in ' in s
                or s.startswith('📊') or s.startswith('•')):
            tag = 'good'
        elif 'WARNING' in s or 'not used' in s:
            tag = 'warn'
        elif 'ERROR' in s or 'FAILED' in s or 'Traceback' in s:
            tag = 'err'

        self._append_log(line, tag)

        if 'finding where the text' in s:
            self.status_var.set('جاري مطابقة أرقام الصفحات مع ملف النص ...')
            self.progress_var.set(8.0)
        elif 'pages,' in s and 'glyphs' in s:
            self.status_var.set('جاري تحليل محارف وخطوط الـ PDF ...')
            self.progress_var.set(15.0)
        elif s.startswith('round '):
            m = re.search(r'round (\d+):\s*([\d.]+)%', s)
            if m:
                r_num = int(m.group(1))
                pct = float(m.group(2))
                self.status_var.set(f'جولة تعلّم الخطوط {r_num}: تطابق {pct:.1f}%')
                self.progress_var.set(min(45.0, 15.0 + r_num * 6.0))
        elif 'reading ' in s and 'pages with OCR' in s:
            self.status_var.set('جاري قراءة الصفحات بالـ OCR ...')
            self.progress_var.set(30.0)
        elif 'OCR' in s and '/' in s and 'pages read' in s:
            m = re.search(r'(\d+)/(\d+)\s+pages read', s)
            if m:
                done, total = int(m.group(1)), int(m.group(2))
                frac = done / max(total, 1)
                self.status_var.set(f'قراءة الـ OCR: {done} من {total} صفحة ({frac:.0%})')
                self.progress_var.set(30.0 + frac * 45.0)
        elif 'OCR (gap strips):' in s:
            m = re.search(r'(\d+)/(\d+)\s+regions read', s)
            if m:
                done, total = int(m.group(1)), int(m.group(2))
                frac = done / max(total, 1)
                self.status_var.set(f'قراءة شرائح الحواشي (Tesseract): {done}/{total}')
                self.progress_var.set(60.0 + frac * 15.0)
        elif 'strong OCR' in s and 'passages read' in s:
            m = re.search(r'(\d+)/(\d+)\s+passages read', s)
            if m:
                done, total = int(m.group(1)), int(m.group(2))
                frac = done / max(total, 1)
                self.status_var.set(f'قراءة الحواشي بنموذج Qari على كرت الشاشة: {done}/{total}')
                if '(Qari on' not in s:  # alongside the CPU, whose pages move the bar
                    self.progress_var.set(75.0 + frac * 12.0)
        elif 'written ' in s:
            self.status_var.set('تم حفظ ملف الكتاب المطبوخ، جاري الفحص ...')
            self.progress_var.set(90.0)
        elif 'checking ...' in s:
            self.status_var.set('جاري التحقق من البكسلات وطبقة النص وخريطة الكلمات ...')
            self.progress_var.set(94.0)

    def _on_process_done(self, rc: int):
        self.is_running = False
        self.proc = None
        self.run_btn.config(state='normal')
        self.stop_btn.config(state='disabled')

        if rc == 0:
            self.progress_var.set(100.0)
            self.status_var.set('✓ اكتمل الطبخ بنجاح!')
            self._load_and_show_report()
        else:
            self.status_var.set('✗ توقفت العملية أو حدث خطأ')
            self.summary_var.set('لم تكتمل العملية — راجع سجل الديبغ لمعرفة السبب.')

    def _load_and_show_report(self):
        if self.mode_var.get() == 'folder':
            folder = Path(self.pdf_var.get().strip())
            self.open_folder_btn.config(state='normal')
            self.summary_var.set(f'✓ اكتمل طبخ كتب المجلد: {folder.name}')
            return

        out_pdf = self.last_out_pdf
        if not out_pdf or not out_pdf.exists():
            return

        self.open_pdf_btn.config(state='normal')
        self.open_folder_btn.config(state='normal')

        dbg_dir = out_pdf.with_name(out_pdf.stem + '.debug')
        if dbg_dir.exists():
            self.last_debug_dir = dbg_dir
            self.open_debug_btn.config(state='normal')
            self._load_debug_images(dbg_dir)

        added_f = out_pdf.with_name(out_pdf.stem + '.added.txt')
        added_content = ''
        if added_f.exists():
            self.last_added_file = added_f
            self.open_added_btn.config(state='normal')
            try:
                added_content = added_f.read_text('utf-8')
            except Exception:
                pass

        rep_f = out_pdf.with_name(out_pdf.stem + '.report.json')
        report_summary_lines = []
        if rep_f.exists():
            try:
                r = json.loads(rep_f.read_text('utf-8'))
                words = r.get('words', 0)
                placed = r.get('placed', 0)
                placed_pct = (placed / max(words, 1)) * 100
                toc = r.get('bookmarks', 0)
                secs = r.get('seconds', 0)
                pages_list = r.get('pages', [])
                text_pages = [p for p in pages_list if p.get('words', 0) > 0 and p.get('match', 0) > 0]
                mean_match_pct = (
                    (sum(p['match'] for p in text_pages) / len(text_pages)) * 100
                    if text_pages else placed_pct
                )
                exact_pages = [p['exact'] for p in pages_list if p.get('exact') is not None]
                mean_exact_pct = (sum(exact_pages) / len(exact_pages)) * 100 if exact_pages else 0.0

                comp = r.get('complete', {})
                added_words = comp.get('added_words', 0)
                added_passages = comp.get('added_passages', 0)
                source_words = max(0, words - added_words)

                tl_before = r.get('text_layer', {}).get('before', {}).get('mean')
                tl_after = r.get('text_layer', {}).get('after', {}).get('mean')
                mc = r.get('check_map', {}).get('boxes_confirmed_share')
                px = r.get('check_pixels', {})

                parts = [
                    f'✓ تطابق الكلام: {mean_match_pct:.2f}%',
                    f'موضعة الكلمات: {placed_pct:.2f}% ({placed:,}/{words:,})',
                    f'المضاف من الـ PDF: {added_words:,} كلمة ({added_passages} حاشية/مقطع)',
                ]
                if tl_after is not None:
                    parts.append(f'طبقة النص: {tl_after * 100:.1f}%')
                if mc is not None:
                    parts.append(f'تأكيد الصناديق: {mc * 100:.2f}%')
                parts.append(f'الزمن: {secs} ث')
                self.summary_var.set('  |  '.join(parts))

                report_summary_lines.append('====================================================================')
                report_summary_lines.append('📊 تقرير نسب التطابق في الكلام ومعلومات المطابقة التفصيلية')
                report_summary_lines.append('====================================================================')
                report_summary_lines.append(f'• الملف الناتج                  : {out_pdf.name}')
                report_summary_lines.append(f'• عدد صفحات الكتاب              : {r.get("input", {}).get("pages", len(pages_list))} صفحة')
                report_summary_lines.append(f'• إجمالي الكلمات النهائية       : {words:,} كلمة')
                report_summary_lines.append(f'• الكلمات الموضعة في صفحاتها     : {placed:,} كلمة ({placed_pct:.2f}%) | غير موضعة: {words - placed:,}')
                report_summary_lines.append(f'• متوسط نسبة تطابق الكلام       : {mean_match_pct:.2f}% عبر {len(text_pages)} صفحة نصية')
                if exact_pages:
                    report_summary_lines.append(f'• نسبة التطابق الحرفي الدقيق     : {mean_exact_pct:.2f}% (Exact Letter Match)')
                report_summary_lines.append(
                    f'• تفصيل مصادر الكلام            : {source_words:,} كلمة من ملف النص الأصلي + '
                    f'{added_words:,} كلمة مضافة من الـ PDF ({added_passages} موضع/حاشية)'
                )
                report_summary_lines.append(
                    f'• عدد الفهارس (Bookmarks)       : {toc} | المحارف المتعلمة: {r.get("learned_glyphs", 0)} | '
                    f'الخطوط المصححة: {len(r.get("fonts_fixed", {}))}'
                )
                if tl_after is not None:
                    b_str = f'{tl_before * 100:.2f}%' if tl_before is not None else 'غير متوفر'
                    report_summary_lines.append(
                        f'• جودة طبقة النص (PDFium)       : كانت {b_str} قبل الطبخ ⟵ أصبحت {tl_after * 100:.2f}% بعد الطبخ'
                    )
                if mc is not None:
                    mc_obj = r.get('check_map', {})
                    report_summary_lines.append(
                        f'• تأكيد صناديق الكلمات هندسياً   : {mc * 100:.2f}% '
                        f'({mc_obj.get("boxes_confirmed", 0):,}/{mc_obj.get("boxes_tested", 0):,} صندوق مطابق)'
                    )
                if px:
                    px_tot = max(1, px.get('pages', 1))
                    px_id = px.get('mupdf_identical', 0)
                    report_summary_lines.append(
                        f'• تطابق البكسلات والصور          : {(px_id / px_tot) * 100:.2f}% ({px_id}/{px_tot} صفحة مطابقة تماماً)'
                    )
                report_summary_lines.append('')
                report_summary_lines.append('--- جدول تفصيل التطابق لكل صفحة ---')
                for p_info in pages_list:
                    ex_str = f' | الدقة الحرفية={p_info["exact"] * 100:.1f}%' if p_info.get('exact') is not None else ''
                    report_summary_lines.append(
                        f'  - صفحة {p_info["page"]:4d}: النوع={p_info["kind"]:6s} | '
                        f'تطابق الكلام={p_info["match"] * 100:6.2f}%{ex_str} | '
                        f'الكلمات الموضعة={p_info["placed"]}/{p_info["words"]} | '
                        f'المضاف من الـ PDF={p_info["added"]}'
                    )
            except Exception:
                self.summary_var.set(f'✓ تم إنتاج الملف بنجاح: {out_pdf.name}')

        # تحديث تبويب قراءة النصوص المضافة والتقرير
        self.added_text.config(state='normal')
        self.added_text.delete('1.0', 'end')
        if report_summary_lines:
            self.added_text.insert('end', '\n'.join(report_summary_lines) + '\n\n' + '=' * 50 + '\n\n')
        if added_content:
            self.added_text.insert('end', added_content)
        elif not report_summary_lines:
            self.added_text.insert('end', 'لا توجد نصوص إضافية مستخرجة من الـ PDF في هذه العملية.')
        self.added_text.config(state='disabled')

    # ---- معاينة صور فحص الصناديق داخل الواجهة ----

    def _load_debug_images(self, folder: Path):
        self.debug_images_list = sorted(folder.glob('page-*.png'))
        self.debug_img_idx = 0
        self.debug_zoom = 1.0
        self._render_current_debug_image()

    def _step_debug_image(self, step: int):
        if not self.debug_images_list:
            return
        self.debug_img_idx = (self.debug_img_idx + step) % len(self.debug_images_list)
        self._render_current_debug_image()

    def _zoom_debug_image(self, factor: float):
        if not self.debug_images_list:
            return
        if factor == 0.0:
            self.debug_zoom = 1.0
        else:
            self.debug_zoom = max(0.3, min(3.0, self.debug_zoom * factor))
        self._render_current_debug_image()

    def _render_current_debug_image(self):
        if not self.debug_images_list:
            self.dbg_page_label_var.set('لا توجد صور فحص حالياً')
            return
        img_path = self.debug_images_list[self.debug_img_idx]
        self.dbg_page_label_var.set(
            f'{img_path.name} ({self.debug_img_idx + 1}/{len(self.debug_images_list)}) — تكبير {self.debug_zoom:.0%}'
        )
        try:
            doc = pymupdf.open(str(img_path))
            page = doc[0]
            mat = pymupdf.Matrix(self.debug_zoom, self.debug_zoom)
            pix = page.get_pixmap(matrix=mat, alpha=False)
            ppm_data = pix.tobytes('ppm')
            doc.close()
            self._tk_img_ref = tk.PhotoImage(data=ppm_data)
            self.img_canvas.delete('all')
            self.img_canvas.create_image(0, 0, anchor='nw', image=self._tk_img_ref)
            self.img_canvas.config(scrollregion=(0, 0, pix.width, pix.height))
        except Exception as e:
            self.dbg_page_label_var.set(f'تعذّر عرض الصورة: {e}')

    # ---- أزرار فتح الملفات والمجلدات ----

    def _open_path(self, path: Path | None):
        if not path or not path.exists():
            return
        if sys.platform == 'win32':
            os.startfile(str(path))
        elif sys.platform == 'darwin':
            subprocess.Popen(['open', str(path)])
        else:
            subprocess.Popen(['xdg-open', str(path)])

    def _open_out_pdf(self):
        self._open_path(self.last_out_pdf)

    def _open_out_folder(self):
        if self.mode_var.get() == 'folder':
            self._open_path(Path(self.pdf_var.get().strip()))
        elif self.last_out_pdf:
            self._open_path(self.last_out_pdf.parent)

    def _open_debug_folder(self):
        self._open_path(self.last_debug_dir)

    def _open_added_file(self):
        self._open_path(self.last_added_file)

    def _clear_log(self):
        self.log_text.config(state='normal')
        self.log_text.delete('1.0', 'end')
        self.log_text.config(state='disabled')

    def _append_log(self, text: str, tag: str = 'info'):
        self.log_text.config(state='normal')
        self.log_text.insert('end', text, tag)
        self.log_text.see('end')
        self.log_text.config(state='disabled')


def main():
    root = tk.Tk()
    app = CookApp(root)
    if len(sys.argv) > 1:
        app.open_book(Path(sys.argv[1]))
    root.mainloop()


if __name__ == '__main__':
    main()
