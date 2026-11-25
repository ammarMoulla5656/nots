@echo off
cd /d "%~dp0.."
chcp 65001 >nul
title أداة تحميل كتب جامع الكتب الإسلامية - KetabOnline to DOCX

echo =====================================================================
echo    أداة تنزيل وتحويل الكتب من موقع جامع الكتب الإسلامية إلى Word
echo =====================================================================
echo.

where python >nul 2>&1
if %errorlevel% neq 0 (
    echo [خطأ] لم يتم العثور على Python في نظامك! يرجى تثبيت Python وإعادة المحاولة.
    pause
    exit /b
)

echo فحص وتثبيت المكتبات المطلوبة إن لزم الأمر...
python -c "import requests, bs4, docx" >nul 2>&1
if %errorlevel% neq 0 (
    echo جاري تثبيت المكتبات (requests, beautifulsoup4, python-docx)...
    python -m pip install requests beautifulsoup4 python-docx
)

echo.
echo جاري بدء تشغيل الأداة...
python "%~dp0ketab_docx_downloader.py"

echo.
echo =====================================================================
echo انتهت العملية! اضغط على أي مفتاح للإغلاق...
echo =====================================================================
pause >nul
