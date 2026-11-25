import time
import copy
from docx import Document
from docx.shared import Pt, RGBColor
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls, qn

doc = Document()
p = doc.add_paragraph()

# Benchmark 1: parse_xml
t0 = time.time()
for _ in range(50000):
    el = parse_xml(r'<w:bidi %s/>' % nsdecls('w'))
print(f"50,000 parse_xml: {time.time() - t0:.2f}s")

# Benchmark 2: OxmlElement
t0 = time.time()
for _ in range(50000):
    el = OxmlElement('w:bidi')
print(f"50,000 OxmlElement: {time.time() - t0:.2f}s")

