# Подготовка к локальному запуску
# Копирует нужные файлы в deploy/

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$deploy = Join-Path $root "deploy"

Write-Host "[prepare] Copying Edge Functions..." -ForegroundColor Cyan
$src = Join-Path $root "supabase\functions"
$dst = Join-Path $deploy "deno-functions\functions"
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
Copy-Item $src $dst -Recurse

Write-Host "[prepare] Checking FFmpeg service..." -ForegroundColor Cyan
$ffmpegSrc = "C:\Cursor\aimuza.ru\ffmpeg\server.js"
if (Test-Path $ffmpegSrc) {
    Write-Host "  FFmpeg server.js found" -ForegroundColor Green
} else {
    Write-Host "  WARNING: FFmpeg server.js not found at $ffmpegSrc" -ForegroundColor Yellow
}

Write-Host "[prepare] Done. Run: docker compose up --build" -ForegroundColor Green
