# AIMUZA - Push images to Docker Hub
# Usage: cd deploy; .\push.ps1

$ErrorActionPreference = "Stop"
$reg = "romzett"
$images = @("aimuza-api", "aimuza-frontend", "aimuza-realtime", "aimuza-ffmpeg", "aimuza-radio", "aimuza-deno")
$localNames = @("deploy-api", "deploy-frontend", "deploy-realtime", "deploy-ffmpeg-api", "deploy-radio", "deploy-deno-functions")

Write-Host "Push to Docker Hub: $reg"
Write-Host ""

# Build with .env.server
Write-Host "Step 1: Build images..."
docker compose --env-file .env.server build
if ($LASTEXITCODE -ne 0) { exit 1 }

# Tag and push
Write-Host ""
Write-Host "Step 2: Tag and push..."
for ($i = 0; $i -lt $images.Length; $i++) {
    $local = "$($localNames[$i]):latest"
    $remote = "$reg/$($images[$i]):latest"
    Write-Host "  $local -> $remote"
    docker tag $local $remote
    docker push $remote
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

Write-Host ""
Write-Host "All images pushed to Docker Hub!"
