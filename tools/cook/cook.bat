@echo off
rem Drop a PDF (or a folder of PDFs) on this file to link it with its Word text.
chcp 65001 >nul
python "%~dp0cook.py" %*
pause
