@echo off
rem Drop a PDF (or a folder of PDFs) on this file to link it with its Word text,
rem or double-click it directly to open the graphical interface.
chcp 65001 >nul
if "%~1"=="" (
    python -X utf8 "%~dp0cook_gui.py"
) else (
    python -X utf8 "%~dp0cook.py" %*
    pause
)
