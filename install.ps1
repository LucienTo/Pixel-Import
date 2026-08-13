# Installs Pixel Import into Aseprite's extensions folder.
# Only ships the runtime files - tests stay in the repo.

$ErrorActionPreference = "Stop"

$src  = $PSScriptRoot
$dest = Join-Path $env:APPDATA "Aseprite\extensions\pixelimport"

if (-not (Test-Path (Join-Path $src "package.json"))) {
    throw "Run this from the Pixel Import project folder."
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dest "src") | Out-Null

Copy-Item (Join-Path $src "package.json") $dest -Force
Copy-Item (Join-Path $src "main.lua")     $dest -Force
Copy-Item (Join-Path $src "src\*.lua")    (Join-Path $dest "src") -Force

Write-Host "Installed Pixel Import to $dest"
Get-ChildItem $dest -Recurse -File | ForEach-Object {
    Write-Host ("  {0}" -f $_.FullName.Substring($dest.Length + 1))
}

if (Get-Process -Name "Aseprite" -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "Aseprite is running - restart it to load the extension." -ForegroundColor Yellow
}
