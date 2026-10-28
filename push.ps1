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

# Export directly from BuildKit. Docker Desktop's containerd docker push can
# stall on existing layers; the registry exporter avoids that path.
Write-Host ""
Write-Host "Step 2: Export release images to registry..."
$planText = docker compose --env-file .env.server -f docker-compose.yml build --print
if ($LASTEXITCODE -ne 0) { exit 1 }
$plan = ($planText -join "`n") | ConvertFrom-Json
$services = @('api','frontend','realtime','ffmpeg-api','radio','deno-functions','studio')
$plan.group.default.targets = $services
foreach ($property in @($plan.target.PSObject.Properties.Name)) {
    if ($services -notcontains $property) { $plan.target.PSObject.Properties.Remove($property) }
}
for ($i = 0; $i -lt $images.Length; $i++) {
    $target = $plan.target.PSObject.Properties[$services[$i]].Value
    if (!$target) { throw "Missing release build target: $($services[$i])" }
    $target | Add-Member -NotePropertyName tags -NotePropertyValue @("$reg/$($images[$i]):latest", "$reg/$($images[$i]):v$version") -Force
    $target | Add-Member -NotePropertyName platforms -NotePropertyValue @('linux/amd64') -Force
    if (![IO.Path]::IsPathRooted($target.context)) {
        $target.context = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $target.context))
    }
}
$apiUrl = $plan.target.frontend.args.VITE_SUPABASE_URL
if (!$apiUrl -or $apiUrl.TrimEnd('/') -ne 'https://aimuza.ru') { throw 'Production frontend API URL is not https://aimuza.ru' }
$checkAssets = 'for file in /usr/share/nginx/html/assets/*.js; do case "$file" in */vendor-*) continue ;; esac; if grep -q "http://localhost" "$file"; then echo "Local API URL in application asset: $(basename "$file")" >&2; exit 1; fi; done'
# The resolved plan may contain build credentials: never log or commit it.
$privateDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\private-local'))
New-Item -ItemType Directory -Force -Path $privateDir | Out-Null
$planPath = Join-Path $privateDir ('.deploy-bake-' + [Guid]::NewGuid().ToString('N') + '.json')
$checkPath = Join-Path $privateDir ('.deploy-assets-' + [Guid]::NewGuid().ToString('N') + '.sh')
try {
    [IO.File]::WriteAllText($planPath,($plan | ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($checkPath,$checkAssets+"`n",[Text.UTF8Encoding]::new($false))
    docker run --rm --network none --entrypoint sh --mount "type=bind,source=$checkPath,target=/check.sh,readonly" deploy-frontend:latest /check.sh
    if ($LASTEXITCODE -ne 0) { throw 'Production frontend contains a localhost application URL' }
    docker buildx bake --file $planPath --provenance=false --push
    if ($LASTEXITCODE -ne 0) { throw 'BuildKit registry export failed' }
} finally {
    Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checkPath -Force -ErrorAction SilentlyContinue
}
Write-Host "All release images exported to Docker Hub!"
