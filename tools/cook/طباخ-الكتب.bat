@echo off
chcp 65001 >nul
start "" pythonw "%~dp0cook_gui.py"
if errorlevel 1 python -X utf8 "%~dp0cook_gui.py"

