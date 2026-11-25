@echo off
rem Opens the PG3D Skin Importer window (Windows PowerShell + WPF, nothing to install).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0PG3D-Skin-Importer.ps1"
