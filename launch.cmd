@echo off
rem SpaceFire AI - start the API and the website (Windows). Options: -Dev  -Rebuild  -Stop  -NoBrowser  -BackendPort N  -FrontendPort N
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1" %*
set "code=%ERRORLEVEL%"
if not "%code%"=="0" pause
exit /b %code%
