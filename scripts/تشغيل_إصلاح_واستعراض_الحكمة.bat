@echo off
cd /d "%~dp0.."
chcp 65001 >nul
title إصلاح واستعراض قاعدة بيانات الحكمة

echo =====================================================================
echo    أداة إصلاح واستعراض قاعدة بيانات الحكمة (alhikmeh.db)
echo =====================================================================
echo.

where python >nul 2>&1
if %errorlevel% neq 0 (
    echo [خطأ] لم يتم العثور على Python في نظامك!
    pause
    exit /b
)

if not exist "alhikmeh_repaired.db" (
    echo [1/2] جاري إصلاح واستعادة قاعدة البيانات...
    python "%~dp0repair_alhikmeh_db.py"
    echo.
)

echo [2/2] تشغيل مستعرض قاعدة البيانات التفاعلي...
python "%~dp0view_alhikmeh.py"

echo.
pause
