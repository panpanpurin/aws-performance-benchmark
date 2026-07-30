@echo off
cd /d "%~dp0"
bash "%~dp0run-parallel.sh"
exit /b %ERRORLEVEL%
