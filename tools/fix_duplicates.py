import os
import sys
sys.path.append(r"d:\01_Projects\mobile\nots")
sys.path.append(r"d:\01_Projects\mobile\nots\scripts")
from batch_export_all_books import export_single_part_worker

tasks = [
    (478, "قواعد الأحكام في معرفة الحلال والحرام", "العلامة الحلي", 21, 3, 760, "03_قسم1", r"d:\01_Projects\mobile\nots\كتب_المكتبة_docx\[ID_478]_[فقه_وأحكام]_[قواعد_الأحكام_في_معرفة_الحلال_والحرام]_ج03_قسم1.docx"),
    (478, "قواعد الأحكام في معرفة الحلال والحرام", "العلامة الحلي", 21, 3, 762, "03_قسم2", r"d:\01_Projects\mobile\nots\كتب_المكتبة_docx\[ID_478]_[فقه_وأحكام]_[قواعد_الأحكام_في_معرفة_الحلال_والحرام]_ج03_قسم2.docx"),
    (2060, "منهاج الصالحين", "السيد علي الحسيني السيستاني", 21, 3, 758, "01_ملحق", r"d:\01_Projects\mobile\nots\كتب_المكتبة_docx\[ID_2060]_[فقه_وأحكام]_[منهاج_الصالحين]_ج01_ملحق.docx"),
    (7049, "الإيضاح في شرح المفصل", "ابن الحاجب", 27, 3, 7049, "المقدمة", r"d:\01_Projects\mobile\nots\كتب_المكتبة_docx\[ID_7049]_[نحو_ولغة]_[الإيضاح_في_شرح_المفصل]_المقدمة.docx")
]

for t in tasks:
    res = export_single_part_worker(t)
    print("Exported:", t[7], "Pages:", res[2], "Error:", res[4])
