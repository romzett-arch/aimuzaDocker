# AIMUZA - Push images to Docker Hub
# Usage: cd deploy; .\push.ps1

$ErrorActionPreference = "Stop"
$reg = "romzett"
$images = @("aimuza-api", "aimuza-frontend", "aimuza-realtime", "aimuza-ffmpeg", "aimuza-radio", "aimuza-deno", "aimuza-studio")
$localNames = @("deploy-api", "deploy-frontend", "deploy-realtime", "deploy-ffmpeg-api", "deploy-radio", "deploy-deno-functions", "aimuza-studio")
$version = (Get-Content (Join-Path $PSScriptRoot "..\package.json") | ConvertFrom-Json).version

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
    if ($images[$i] -eq "aimuza-studio") {
        # Docker's containerd push can stall on an existing Studio layer. Use
        # BuildKit's registry exporter with the same Dockerfile and build arg.
        $apkLine = Get-Content .env.server | Where-Object { $_ -match '^NEXT_PUBLIC_ANDROID_APK_URL=' } | Select-Object -First 1
        $apkUrl = if ($apkLine) { $apkLine.Substring('NEXT_PUBLIC_ANDROID_APK_URL='.Length).Trim().Trim('"').Trim("'") } else { "" }
        docker buildx build --platform linux/amd64 --provenance=false --push --build-arg "NEXT_PUBLIC_ANDROID_APK_URL=$apkUrl" --tag "$reg/aimuza-studio:latest" --tag "$reg/aimuza-studio:v$version" --file ../apps/studio/Dockerfile ../apps/studio
        if ($LASTEXITCODE -ne 0) { exit 1 }
        continue
    }
    $local = "$($localNames[$i]):latest"
    foreach ($tag in @("latest", "v$version")) {
        $remote = "$reg/$($images[$i]):$tag"
        Write-Host "  $local -> $remote"
        docker tag $local $remote
        docker push $remote
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
}

Write-Host ""
Write-Host "All images pushed to Docker Hub!"
