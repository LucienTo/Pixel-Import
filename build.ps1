# Builds the installable extension file: pixel-import.aseprite-extension
#
# An Aseprite extension is a zip of the runtime files with package.json at its
# root. Entry names are written with forward slashes explicitly, because
# Compress-Archive writes Windows separators into the archive and Aseprite on
# macOS and Linux then sees one file called "src\convert.lua" instead of a src
# folder. Tests are not shipped.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$src  = $PSScriptRoot
$name = "pixel-import.aseprite-extension"
$out  = Join-Path $src $name

if (-not (Test-Path (Join-Path $src "package.json"))) {
    throw "Run this from the Pixel Import project folder."
}

$files = @(
    @{ Path = "package.json"; Entry = "package.json" },
    @{ Path = "main.lua";     Entry = "main.lua" }
)
Get-ChildItem (Join-Path $src "src") -Filter *.lua | Sort-Object Name | ForEach-Object {
    $files += @{ Path = "src\$($_.Name)"; Entry = "src/$($_.Name)" }
}

Remove-Item $out -Force -ErrorAction SilentlyContinue
$zip = [System.IO.Compression.ZipFile]::Open($out, "Create")
try {
    foreach ($f in $files) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, (Join-Path $src $f.Path), $f.Entry) | Out-Null
    }
} finally {
    $zip.Dispose()
}

$version = (Get-Content (Join-Path $src "package.json") -Raw | ConvertFrom-Json).version
Write-Host ("Built {0} (version {1}, {2:N0} bytes)" -f $name, $version, (Get-Item $out).Length)
foreach ($f in $files) { Write-Host ("  {0}" -f $f.Entry) }
