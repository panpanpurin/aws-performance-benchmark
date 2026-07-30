@echo off
REM Calls bash script (needs Git Bash or WSL on PATH as "bash")
cd /d "%~dp0"
bash "%~dp0run-parallel.sh"
exit /b %ERRORLEVEL%
