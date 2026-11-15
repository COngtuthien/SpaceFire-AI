@echo off
rem SpaceFire AI - one-step setup (Windows). Options: -SetOpenAIKey  -RebuildData  -SkipBuild
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1" %*
set "code=%ERRORLEVEL%"
if not "%code%"=="0" pause
exit /b %code%
