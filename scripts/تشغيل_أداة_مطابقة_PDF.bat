@echo off
cd /d "%~dp0.."
start "" "http://127.0.0.1:8505"
python "%~dp0book_pdf_matcher_app.py"
pause
