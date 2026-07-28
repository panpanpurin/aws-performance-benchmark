# Shared parallel Artillery runner for EC2 + ECS + Lambda.
# Usage: .\run-parallel.ps1 -Suite anilove|csv-processor|thumbnail-generator
# Prerequisite: metrics stack up for that suite (make bench-*).
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("anilove", "csv-processor", "thumbnail-generator")]
  [string]$Suite
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $ScriptDir "..\..")
$ArtDir = Join-Path $Root "benchmarks\suites\$Suite\artillery"

if (-not (Test-Path $ArtDir)) {
  throw "Unknown suite or missing artillery dir: $ArtDir"
}

$meta = @{
  "anilove" = @{
    Title = "AniLove"; Prom = "http://localhost:9090"; Graf = "http://localhost:3002"
    Pg = "9092 / 9093 / 9094"; Make = "bench-anilove"
  }
  "csv-processor" = @{
    Title = "CSV Processor"; Prom = "http://localhost:9190"; Graf = "http://localhost:3102"
    Pg = "9192 / 9193 / 9194"; Make = "bench-csv"
  }
  "thumbnail-generator" = @{
    Title = "Thumbnail"; Prom = "http://localhost:9290"; Graf = "http://localhost:3202"
    Pg = "9292 / 9293 / 9294"; Make = "bench-thumbnail"
  }
}[$Suite]

Set-Location $ArtDir
$tests = @(
  @{ Name = "ec2";    File = "test-ec2.yml" },
  @{ Name = "ecs";    File = "test-ecs.yml" },
  @{ Name = "lambda"; File = "test-lambda.yml" }
)
foreach ($t in $tests) {
  if (-not (Test-Path $t.File)) { throw "Missing file: $($t.File)" }
}

New-Item -ItemType Directory -Force -Path "logs" | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Host "========================================"
Write-Host " $($meta.Title) - parallel EC2 / ECS / Lambda"
Write-Host " Prerequisite: make $($meta.Make)"
Write-Host " Prometheus: $($meta.Prom)"
Write-Host " Grafana:    $($meta.Graf)"
Write-Host " Pushgateway ECS/EC2/Lambda: $($meta.Pg)"
Write-Host "========================================"
Write-Host ""

$procs = @()
foreach ($t in $tests) {
  $log = Join-Path $ArtDir "logs\$($t.Name)-$stamp.log"
  Write-Host "[$($t.Name.ToUpper())] starting -> $log"
  $procs += Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", "npx --yes artillery@2.0.23 run $($t.File) > `"$log`" 2>&1" `
    -WorkingDirectory $ArtDir `
    -PassThru `
    -WindowStyle Minimized
}

Write-Host ""
Write-Host "Waiting for all three to finish..."
$failed = $false
foreach ($i in 0..($procs.Count - 1)) {
  $p = $procs[$i]
  $name = $tests[$i].Name
  Wait-Process -Id $p.Id
  if ($p.ExitCode -ne 0) {
    Write-Host "[$name] FAILED exit=$($p.ExitCode) - see logs\$name-$stamp.log" -ForegroundColor Red
    $failed = $true
  } else {
    Write-Host "[$name] OK"
  }
}

if ($failed) { exit 1 }
Write-Host ""
Write-Host "All parallel tests finished. Compare instance=ec2|ecs|lambda in Grafana."
