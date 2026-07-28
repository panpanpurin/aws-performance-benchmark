# Thin wrapper -> shared runner
& (Join-Path $PSScriptRoot "..\..\..\scripts\run-parallel.ps1") -Suite thumbnail-generator
exit $LASTEXITCODE
