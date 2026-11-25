@echo off
title Book PDF Matcher Studio
cd /d "%~dp0.."
echo =====================================================================
echo    Book PDF Matcher Studio - Starting Web Server on port 8500...
echo =====================================================================
echo.
python "%~dp0book_pdf_matcher_app.py"
if errorlevel 1 (
    echo.
    echo [ERROR] An error occurred while starting the server.
    pause
)
