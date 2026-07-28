@echo off
title CSV parallel Artillery (EC2 + ECS + Lambda)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-parallel.ps1"
set ERR=%ERRORLEVEL%
echo.
if %ERR% neq 0 ( echo FAILED. See logs\ & pause & exit /b %ERR% )
echo Done. Use Grafana over this time window for side-by-side charts.
pause
exit /b 0
