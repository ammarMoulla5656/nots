"""Nots publisher: adds, edits and removes the books of the app's library.

Run: python publish.py   (or publish.bat)
"""

from __future__ import annotations

import os
import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from PIL import Image, ImageOps, ImageTk

from nots_publisher import catalog as cat
from nots_publisher import publishing
from nots_publisher.inspect_book import inspect
from nots_publisher.publishing import BookDraft, PartDraft
from nots_publisher.server import Account, Server

FIELD_LABELS = (
    ("title", "اسم الكتاب *"),
    ("author", "المؤلف"),
    ("investigator", "المحقق"),
    ("edition", "الطبعة"),
    ("language", "اللغة"),
    ("subject", "التصنيف"),
    ("publisher", "الناشر"),
)
SUGGESTED = ("language", "subject", "publisher", "author")
FEATURE_LABELS = (
    ("search", "بحث"),
    ("marks", "تعليم الكلمات"),
    ("copy", "نسخ النص"),
    ("toc", "فهرس"),
    ("exact", "نص مصحَّح"),
)
NO_FEATURES = {k: False for k, _ in FEATURE_LABELS}


class AccountDialog(tk.Toplevel):
    def __init__(self, parent: tk.Tk, account: Account):
        super().__init__(parent)
        self.title("بيانات السيرفر")
        self.result: Account | None = None
        self.resizable(False, False)
        self.vars = {}
        rows = (("host", "السيرفر", account.host, ""),
                ("port", "المنفذ", str(account.port), ""),
                ("user", "المستخدم", account.user, ""),
                ("password", "كلمة المرور", account.password, "•"))
        for i, (key, label, value, show) in enumerate(rows):
            ttk.Label(self, text=label).grid(row=i, column=1, sticky="e", padx=8, pady=4)
            var = tk.StringVar(value=value)
            ttk.Entry(self, textvariable=var, width=34, show=show).grid(row=i, column=0, padx=8)
            self.vars[key] = var
        ttk.Button(self, text="حفظ", command=self._ok).grid(row=len(rows), column=0, columnspan=2, pady=8)
        self.transient(parent)
        self.grab_set()

    def _ok(self) -> None:
        v = {k: x.get().strip() for k, x in self.vars.items()}
        self.result = Account(v["host"], int(v["port"] or 21), v["user"], v["password"])
        self.destroy()


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("نوتس: رفع الكتب")
        height = min(780, self.winfo_screenheight() - 90)
        self.geometry(f"1120x{height}+40+10")
        self.minsize(980, 600)
        self.account = Account.load()
        self.catalog = cat.empty()
        self.events: queue.Queue = queue.Queue()
        self.busy = False
        self.book_id: str | None = None
        self.parts: list[PartDraft] = []
        self.cover_local: str | None = None
        self.cover_existing = ""
        self.cover_image = None
        self._build()
        self.after(100, self._pump)
        self.after(200, self._first_load)

    # ---------------------------------------------------------------- layout

    def _build(self) -> None:
        top = ttk.Frame(self, padding=(10, 8))
        top.pack(fill="x")
        ttk.Button(top, text="بيانات السيرفر", command=self._edit_account).pack(side="left")
        ttk.Button(top, text="تحديث القائمة", command=self._refresh).pack(side="left", padx=6)
        self.count_label = ttk.Label(top, text="")
        self.count_label.pack(side="right")

        self._build_bottom()
        body = ttk.Frame(self, padding=(10, 0))
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=3)
        body.columnconfigure(1, weight=2)
        body.rowconfigure(0, weight=1)
        self._build_form(body)
        self._build_list(body)

    def _build_bottom(self) -> None:
        """Packed first, so it stays on screen however small the window is."""
        bottom = ttk.Frame(self, padding=10)
        bottom.pack(side="bottom", fill="x")
        self.publish_button = ttk.Button(bottom, text="نشر الكتاب", command=self._publish)
        self.publish_button.pack(side="right", ipadx=30, ipady=6, padx=(10, 0))
        self.status = ttk.Label(bottom, text="", anchor="e")
        self.status.pack(fill="x")
        self.progress = ttk.Progressbar(bottom, mode="determinate", maximum=1000)
        self.progress.pack(fill="x", pady=(4, 0))

    def _build_list(self, parent: ttk.Frame) -> None:
        box = ttk.LabelFrame(parent, text="الكتب المنشورة", padding=8)
        box.grid(row=0, column=1, sticky="nsew", padx=(10, 0))
        self.filter = tk.StringVar()
        self.filter.trace_add("write", lambda *_: self._fill_list())
        ttk.Entry(box, textvariable=self.filter, justify="right").pack(fill="x", pady=(0, 6))
        frame = ttk.Frame(box)
        frame.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(frame, columns=("parts", "title"), show="headings", selectmode="browse")
        self.tree.heading("title", text="الكتاب", anchor="e")
        self.tree.heading("parts", text="الأجزاء", anchor="center")
        self.tree.column("title", anchor="e", width=260)
        self.tree.column("parts", anchor="center", width=60, stretch=False)
        bar = ttk.Scrollbar(frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=bar.set)
        self.tree.pack(side="left", fill="both", expand=True)
        bar.pack(side="right", fill="y")
        self.tree.bind("<<TreeviewSelect>>", self._on_pick)
        actions = ttk.Frame(box)
        actions.pack(fill="x", pady=(6, 0))
        ttk.Button(actions, text="كتاب جديد", command=self._new).pack(side="right")
        self.delete_button = ttk.Button(actions, text="حذف الكتاب", command=self._delete)
        self.delete_button.pack(side="left")

    def _build_form(self, parent: ttk.Frame) -> None:
        box = ttk.LabelFrame(parent, text="معلومات الكتاب", padding=8)
        box.grid(row=0, column=0, sticky="nsew")
        box.columnconfigure(0, weight=1)
        box.rowconfigure(2, weight=1)

        head = ttk.Frame(box)
        head.grid(row=0, column=0, sticky="ew")
        head.columnconfigure(1, weight=1)
        cover = ttk.Frame(head)
        cover.grid(row=0, column=0, sticky="n", padx=(0, 12))
        self.cover_view = tk.Label(cover, text="بلا صورة", width=18, height=9, relief="groove")
        self.cover_view.pack()
        ttk.Button(cover, text="اختيار صورة", command=self._pick_cover).pack(fill="x", pady=(6, 0))

        fields = ttk.Frame(head)
        fields.grid(row=0, column=1, sticky="nsew")
        fields.columnconfigure(0, weight=1)
        self.inputs: dict[str, tk.StringVar] = {}
        self.combos: dict[str, ttk.Combobox] = {}
        for i, (key, label) in enumerate(FIELD_LABELS):
            var = tk.StringVar()
            self.inputs[key] = var
            if key in SUGGESTED:
                w = ttk.Combobox(fields, textvariable=var, justify="right")
                self.combos[key] = w
            else:
                w = ttk.Entry(fields, textvariable=var, justify="right")
            w.grid(row=i, column=0, sticky="ew", pady=2)
            ttk.Label(fields, text=label).grid(row=i, column=1, sticky="e", padx=(8, 0))

        kind = ttk.Frame(box)
        kind.grid(row=1, column=0, sticky="ew", pady=(10, 4))
        self.kind = tk.StringVar(value="single")
        ttk.Label(kind, text="نوع الكتاب:").pack(side="right")
        ttk.Radiobutton(kind, text="كتاب مفرد", value="single", variable=self.kind,
                        command=self._kind_changed).pack(side="right", padx=8)
        ttk.Radiobutton(kind, text="عدة أجزاء", value="multi", variable=self.kind,
                        command=self._kind_changed).pack(side="right")
        self.total = tk.StringVar(value="1")
        self.total_box = ttk.Spinbox(kind, from_=1, to=500, width=5, textvariable=self.total)
        self.total_box.pack(side="left")
        ttk.Label(kind, text="عدد الأجزاء الكلي").pack(side="left", padx=6)

        parts = ttk.Frame(box)
        parts.grid(row=2, column=0, sticky="nsew")
        parts.rowconfigure(0, weight=1)
        parts.columnconfigure(0, weight=1)
        self.part_tree = ttk.Treeview(parts, columns=("state", "file", "pages", "format", "label"),
                                      show="headings", selectmode="browse", height=4)
        for key, text, width in (("label", "الجزء", 110), ("format", "الصيغة", 60), ("pages", "الصفحات", 60),
                                 ("file", "الملف", 260), ("state", "الحالة", 80)):
            self.part_tree.heading(key, text=text, anchor="e")
            self.part_tree.column(key, width=width, anchor="e", stretch=key == "file")
        self.part_tree.grid(row=0, column=0, sticky="nsew")
        self.part_tree.bind("<<TreeviewSelect>>", lambda _: self._show_part())

        row = ttk.Frame(box)
        row.grid(row=3, column=0, sticky="ew", pady=(6, 0))
        self.add_button = ttk.Button(row, text="إضافة ملف", command=self._add_files)
        self.add_button.pack(side="right")
        ttk.Button(row, text="إزالة", command=self._drop_part).pack(side="right", padx=6)
        self.up_button = ttk.Button(row, text="أعلى", command=lambda: self._move_part(-1))
        self.up_button.pack(side="right")
        self.down_button = ttk.Button(row, text="أسفل", command=lambda: self._move_part(1))
        self.down_button.pack(side="right", padx=6)
        ttk.Button(row, text="تسمية الجزء", command=self._rename_part).pack(side="right")

        feats = ttk.LabelFrame(box, text="ما يدعمه الملف المحدد (يظهر للمستخدم)", padding=6)
        feats.grid(row=4, column=0, sticky="ew", pady=(8, 0))
        self.feature_vars: dict[str, tk.BooleanVar] = {}
        for key, label in FEATURE_LABELS:
            var = tk.BooleanVar()
            self.feature_vars[key] = var
            ttk.Checkbutton(feats, text=label, variable=var, command=self._features_changed).pack(side="right", padx=6)
        self._kind_changed()

    # ---------------------------------------------------------- server tasks

    def _first_load(self) -> None:
        if self.account.user:
            self._refresh()
        else:
            self._edit_account()

    def _edit_account(self) -> None:
        d = AccountDialog(self, self.account)
        self.wait_window(d)
        if d.result:
            self.account = d.result
            self.account.save()
            self._refresh()

    def _run(self, work, done) -> None:
        """Runs [work(server, say)] away from the window, then [done(result)]."""
        if self.busy:
            return
        self.busy = True
        self.publish_button.state(["disabled"])

        def say(text: str, sent: int = 0, total: int = 0) -> None:
            self.events.put(("say", text, sent, total))

        def body() -> None:
            try:
                with Server(self.account) as server:
                    self.events.put(("done", done, work(server, say)))
            except Exception as e:  # shown to the user, whatever it was
                self.events.put(("error", e))

        threading.Thread(target=body, daemon=True).start()

    def _pump(self) -> None:
        try:
            while True:
                event = self.events.get_nowait()
                if event[0] == "say":
                    _, text, sent, total = event
                    self.progress["value"] = 1000 * sent / total if total else 0
                    suffix = f" {100 * sent // total}%" if total else ""
                    self.status["text"] = text + suffix
                    continue
                self.busy = False
                self.publish_button.state(["!disabled"])
                self.progress["value"] = 0
                if event[0] == "done":
                    event[1](event[2])
                else:
                    self.status["text"] = ""
                    messagebox.showerror("تعذّر التنفيذ", str(event[1]))
        except queue.Empty:
            pass
        self.after(100, self._pump)

    def _refresh(self) -> None:
        def work(server, say):
            say("قراءة الفهرس من السيرفر")
            return publishing.load_catalog(server)

        self._run(work, self._loaded)

    def _loaded(self, catalog: dict) -> None:
        self.catalog = catalog
        self.status["text"] = "تم"
        self._fill_list()
        for key, box in self.combos.items():
            box["values"] = cat.values_of(catalog, key)
        self.count_label["text"] = f"{len(catalog['books'])} كتاب"

    def _fill_list(self) -> None:
        q = self.filter.get().strip()
        self.tree.delete(*self.tree.get_children())
        for b in sorted(self.catalog["books"], key=lambda x: x["title"]):
            if q and q not in b["title"] and q not in b.get("author", ""):
                continue
            self.tree.insert("", "end", iid=b["id"], values=(len(b["parts"]), b["title"]))

    # ------------------------------------------------------------------ form

    def _new(self) -> None:
        self.tree.selection_remove(*self.tree.selection())
        self.book_id = None
        for key, var in self.inputs.items():
            var.set("العربية" if key == "language" else "")
        self.parts = []
        self.cover_local = None
        self.cover_existing = ""
        self._show_cover(None)
        self.kind.set("single")
        self.total.set("1")
        self._kind_changed()
        self._fill_parts()
        self.publish_button["text"] = "نشر الكتاب"

    def _on_pick(self, _=None) -> None:
        sel = self.tree.selection()
        book = cat.find(self.catalog, sel[0]) if sel else None
        if book is None:
            return
        self.book_id = book["id"]
        for key, var in self.inputs.items():
            var.set(book.get(key, ""))
        self.parts = [
            PartDraft(p["n"], p.get("label", ""), p["format"], p.get("pages", 0),
                      dict(p.get("features", NO_FEATURES)), existing=p)
            for p in book["parts"]
        ]
        self.cover_local = None
        self.cover_existing = book.get("cover", "")
        self._show_cover(None, "صورة منشورة" if self.cover_existing else "بلا صورة")
        multi = book.get("parts_count", 1) > 1 or len(self.parts) > 1
        self.kind.set("multi" if multi else "single")
        self.total.set(str(book.get("parts_count", 1)))
        self._kind_changed()
        self._fill_parts()
        self.publish_button["text"] = "حفظ التعديلات"

    def _kind_changed(self) -> None:
        multi = self.kind.get() == "multi"
        state = ["!disabled"] if multi else ["disabled"]
        for w in (self.total_box, self.up_button, self.down_button):
            w.state(state)
        self.add_button["text"] = "إضافة أجزاء" if multi else "اختيار الملف"
        if not multi:
            self.total.set("1")
            del self.parts[1:]
            if self.parts:
                self.parts[0].label = ""
            self._fill_parts()

    def _pick_cover(self) -> None:
        path = filedialog.askopenfilename(
            title="صورة الكتاب",
            filetypes=[("صور", "*.jpg *.jpeg *.png *.webp *.bmp"), ("الكل", "*.*")],
        )
        if path:
            self.cover_local = path
            self._show_cover(path)

    def _show_cover(self, path: str | None, text: str = "بلا صورة") -> None:
        if path is None:
            self.cover_image = None
            self.cover_view.configure(image="", text=text, width=18, height=9)
            return
        try:
            with Image.open(path) as im:
                im = ImageOps.exif_transpose(im).convert("RGB")
                im.thumbnail((130, 170))
                self.cover_image = ImageTk.PhotoImage(im)
            self.cover_view.configure(image=self.cover_image, text="", width=130, height=170)
        except OSError as e:
            self.cover_local = None
            messagebox.showerror("الصورة", str(e))

    def _add_files(self) -> None:
        multi = self.kind.get() == "multi"
        types = [("كتب", "*.pdf *.nots"), ("الكل", "*.*")]
        paths = (filedialog.askopenfilenames(title="ملفات الأجزاء", filetypes=types) if multi else
                 [p for p in [filedialog.askopenfilename(title="ملف الكتاب", filetypes=types)] if p])
        for path in sorted(paths):
            try:
                info = inspect(path)
            except Exception as e:
                messagebox.showerror(os.path.basename(path), str(e))
                continue
            if not multi:
                self.parts.clear()
            n = len(self.parts) + 1
            self.parts.append(PartDraft(n, f"الجزء {n}" if multi else "", info["format"],
                                        info["pages"], info["features"], local=path))
        if multi:
            self.total.set(str(max(int(self.total.get() or 1), len(self.parts))))
        self._fill_parts()
        if self.parts:
            self.part_tree.selection_set(str(len(self.parts) - 1))

    def _fill_parts(self) -> None:
        self.part_tree.delete(*self.part_tree.get_children())
        for i, p in enumerate(self.parts):
            name = os.path.basename(p.local) if p.local else p.existing["file"].split("/")[-1]
            state = "جديد" if p.local else "منشور"
            self.part_tree.insert("", "end", iid=str(i),
                                  values=(state, name, p.pages, p.format, p.label or "الكتاب"))
        self._show_part()

    def _picked_part(self) -> int | None:
        sel = self.part_tree.selection()
        return int(sel[0]) if sel else None

    def _show_part(self) -> None:
        i = self._picked_part()
        feats = self.parts[i].features if i is not None else NO_FEATURES
        for key, var in self.feature_vars.items():
            var.set(bool(feats.get(key)))

    def _features_changed(self) -> None:
        i = self._picked_part()
        if i is None:
            return
        self.parts[i].features = {k: v.get() for k, v in self.feature_vars.items()}

    def _renumber(self) -> None:
        multi = self.kind.get() == "multi"
        for i, p in enumerate(self.parts, 1):
            auto = p.label == f"الجزء {p.number}"
            p.number = i
            if multi and (auto or not p.label):
                p.label = f"الجزء {i}"

    def _drop_part(self) -> None:
        i = self._picked_part()
        if i is not None:
            del self.parts[i]
            self._renumber()
            self._fill_parts()

    def _move_part(self, step: int) -> None:
        i = self._picked_part()
        if i is None or not 0 <= i + step < len(self.parts):
            return
        self.parts[i], self.parts[i + step] = self.parts[i + step], self.parts[i]
        self._renumber()
        self._fill_parts()
        self.part_tree.selection_set(str(i + step))

    def _rename_part(self) -> None:
        i = self._picked_part()
        if i is None or self.kind.get() != "multi":
            return
        win = tk.Toplevel(self)
        win.title("تسمية الجزء")
        var = tk.StringVar(value=self.parts[i].label)
        entry = ttk.Entry(win, textvariable=var, width=36, justify="right")
        entry.pack(padx=12, pady=10)
        entry.focus_set()

        def save(_=None) -> None:
            self.parts[i].label = var.get().strip()
            win.destroy()
            self._fill_parts()

        entry.bind("<Return>", save)
        ttk.Button(win, text="حفظ", command=save).pack(pady=(0, 10))
        win.transient(self)
        win.grab_set()

    # --------------------------------------------------------------- actions

    def _publish(self) -> None:
        fields = {k: v.get().strip() for k, v in self.inputs.items()}
        if not fields["title"]:
            messagebox.showwarning("ناقص", "اكتب اسم الكتاب.")
            return
        if not self.parts:
            messagebox.showwarning("ناقص", "اختر ملف الكتاب.")
            return
        multi = self.kind.get() == "multi"
        draft = BookDraft(
            fields=fields,
            parts_count=int(self.total.get() or 1) if multi else 1,
            parts=list(self.parts),
            book_id=self.book_id,
            cover_local=self.cover_local,
            cover_existing=self.cover_existing,
        )

        def work(server, say):
            book = publishing.publish(server, draft, say)
            return book, publishing.load_catalog(server)

        def done(result) -> None:
            book, catalog = result
            self._loaded(catalog)
            self.tree.selection_set(book["id"])
            self.status["text"] = f"نُشر «{book['title']}»"

        self._run(work, done)

    def _delete(self) -> None:
        sel = self.tree.selection()
        book = cat.find(self.catalog, sel[0]) if sel else None
        if book is None:
            return
        if not messagebox.askyesno("حذف", f"حذف «{book['title']}» وملفاته من السيرفر؟"):
            return

        def work(server, say):
            publishing.unpublish(server, book["id"], say)
            return publishing.load_catalog(server)

        def done(catalog) -> None:
            self._new()
            self._loaded(catalog)

        self._run(work, done)


def main() -> None:
    try:  # sharp text on scaled screens
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass
    App().mainloop()


if __name__ == "__main__":
    main()
