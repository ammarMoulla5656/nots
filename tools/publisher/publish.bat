@echo off
cd /d "%~dp0"
python publish.py
if errorlevel 1 pause
