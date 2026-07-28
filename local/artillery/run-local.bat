@echo off
setlocal
cd /d "%~dp0"

echo.
echo === Local Artillery (Docker apps on localhost) ===
echo Prerequisite: local stack running
echo   make local-up
echo   # or: docker compose up -d --build
echo.

if not exist node_modules (
  echo Installing dependencies...
  call npm install
  if errorlevel 1 exit /b 1
)

if "%1"=="" goto all
if /i "%1"=="anilove" goto anilove
if /i "%1"=="csv" goto csv
if /i "%1"=="thumbnail" goto thumbnail
if /i "%1"=="all" goto all

echo Usage: run-local.bat [anilove^|csv^|thumbnail^|all]
exit /b 1

:anilove
echo [AniLove] ...
call npx artillery run test-anilove-local.yml
exit /b %errorlevel%

:csv
echo [CSV] ...
call npx artillery run test-csv-local.yml
exit /b %errorlevel%

:thumbnail
echo [Thumbnail] ...
call npx artillery run test-thumbnail-local.yml
exit /b %errorlevel%

:all
echo [1/3] AniLove
call npx artillery run test-anilove-local.yml
if errorlevel 1 exit /b 1
echo [2/3] CSV
call npx artillery run test-csv-local.yml
if errorlevel 1 exit /b 1
echo [3/3] Thumbnail
call npx artillery run test-thumbnail-local.yml
if errorlevel 1 exit /b 1
echo.
echo All local tests finished.
exit /b 0
