# Build and push EC2/ECS (:latest) and Lambda (:lambda) images to ECR.
# Run from repo root. Needs: AWS CLI credentials, Docker Desktop.
#
#   .\scripts\push-ecr.ps1
#   .\scripts\push-ecr.ps1 -App anilove
#   .\scripts\push-ecr.ps1 -Region ap-northeast-1 -Project aws-perf-bench

param(
  [string]$Region = "ap-northeast-1",
  [string]$Project = "aws-perf-bench",
  [ValidateSet("all", "anilove", "csv", "thumbnail")]
  [string]$App = "all"
)

$ErrorActionPreference = "Stop"

$apps = @{
  anilove   = @{ Dir = "apps/anilove"; Repo = "$Project/anilove" }
  csv       = @{ Dir = "apps/csv-processor"; Repo = "$Project/csv-processor" }
  thumbnail = @{ Dir = "apps/thumbnail-generator"; Repo = "$Project/thumbnail-generator" }
}

$keys = if ($App -eq "all") { @("anilove", "csv", "thumbnail") } else { @($App) }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$account = aws sts get-caller-identity --query Account --output text
if (-not $account) { throw "aws sts get-caller-identity failed. Configure AWS CLI first." }

$registry = "$account.dkr.ecr.$Region.amazonaws.com"
Write-Host "Account  $account"
Write-Host "Region   $Region"
Write-Host "Registry $registry"
Write-Host ""

Write-Host "Logging in to ECR..."
aws ecr get-login-password --region $Region |
  docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "docker login failed" }

function Push-AppImage {
  param(
    [string]$Name,
    [string]$Dir,
    [string]$Repo,
    [string]$Dockerfile,
    [string]$Tag
  )

  $context = Join-Path $root $Dir
  $df = Join-Path $context $Dockerfile
  if (-not (Test-Path $df)) { throw "Missing $df" }

  $local = "${Repo}:$Tag"
  $remote = "${registry}/${Repo}:$Tag"

  Write-Host ""
  Write-Host "==> Build $Name ($Tag) from $Dockerfile"
  docker build -t $local -f $df $context
  if ($LASTEXITCODE -ne 0) { throw "docker build failed for $Name $Tag" }

  docker tag $local $remote
  Write-Host "==> Push $remote"
  docker push $remote
  if ($LASTEXITCODE -ne 0) { throw "docker push failed for $remote" }
}

foreach ($k in $keys) {
  $a = $apps[$k]
  Push-AppImage -Name $k -Dir $a.Dir -Repo $a.Repo -Dockerfile "Dockerfile" -Tag "latest"
  Push-AppImage -Name $k -Dir $a.Dir -Repo $a.Repo -Dockerfile "Dockerfile.lambda" -Tag "lambda"
}

Write-Host ""
Write-Host "Done. Images pushed for: $($keys -join ', ')"
Write-Host "Next: set enable_ec2/ecs/lambda = true in terraform.tfvars and run make apply"
