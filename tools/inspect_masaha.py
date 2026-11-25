import urllib.request
import re

req = urllib.request.Request('https://www.masaha.org/main.2bc12237d7e05462.js', headers={'User-Agent': 'Mozilla/5.0'})
js = urllib.request.urlopen(req, timeout=10).read().decode('utf-8', 'ignore')

print("Total JS length:", len(js))

# Look for URL constructions with api
api_patterns = re.findall(r'(\$\{[^}]+\}/api/[^\s`"\']+)', js)
print("api pattern matches:", api_patterns[:15])

# Look for routes or endpoints
endpoints = re.findall(r'["\'](/api/[^"\']+)["\']', js)
print("api string literals:", endpoints[:15])

# Search for pdf references
pdf_refs = re.findall(r'["\'][^"\']*pdf[^"\']*["\']', js, re.IGNORECASE)
print("pdf refs sample:", [p for p in pdf_refs if len(p) < 40][:15])

# Search for book reading / page reading
page_refs = re.findall(r'["\'][^"\']*/book/[^"\']*["\']', js, re.IGNORECASE)
print("book refs sample:", page_refs[:15])
