param(
    [string]$Flutter = 'flutter.bat',
    [string]$Wix = 'wix.exe',
    [string]$CacheDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
$version = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
if (!$version) { throw 'Could not determine the app version from pubspec.yaml' }

$artifacts = Join-Path $root 'artifacts'
if (!$CacheDirectory) { $CacheDirectory = Join-Path $artifacts 'cache' }
if (!$OutputDirectory) { $OutputDirectory = $artifacts }
$cache = (New-Item -ItemType Directory -Force -Path $CacheDirectory).FullName
$output = (New-Item -ItemType Directory -Force -Path $OutputDirectory).FullName
$stage = (New-Item -ItemType Directory -Force -Path (Join-Path $artifacts ('build-' + [Guid]::NewGuid().ToString('N')))).FullName
$payload = (New-Item -ItemType Directory -Path (Join-Path $stage 'payload')).FullName

$mediaVersion = '1.21.3'
$mediaName = "mediamtx_v${mediaVersion}_windows_amd64.zip"
$mediaArchive = Join-Path $cache $mediaName
$mediaSha = 'b2f5246b07cb72961df03b8d5e8cad43dc657bcf3f49a87bb031bdf22721af74'
if (!(Test-Path -LiteralPath $mediaArchive -PathType Leaf) -or
    (Get-FileHash -LiteralPath $mediaArchive -Algorithm SHA256).Hash -ne $mediaSha) {
    & curl.exe --fail --silent --show-error --location --retry 2 --max-time 120 -o $mediaArchive `
        "https://github.com/bluenviron/mediamtx/releases/download/v$mediaVersion/$mediaName"
    if ($LASTEXITCODE -ne 0) { throw 'MediaMTX download failed' }
}
if ((Get-FileHash -LiteralPath $mediaArchive -Algorithm SHA256).Hash -ne $mediaSha) {
    throw 'MediaMTX SHA-256 mismatch'
}

Push-Location -LiteralPath $root
try {
    & $Flutter --no-version-check pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter package restore failed' }
    & $Flutter --no-version-check build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed' }
}
finally {
    Pop-Location
}

$build = Join-Path $root 'build/windows/x64'
$bundle = Join-Path $build 'runner/Release'
foreach ($name in @('rtmp_live_desk.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so')) {
    if (!(Test-Path -LiteralPath (Join-Path $bundle $name) -PathType Leaf)) {
        throw "The Windows x64 bundle is missing $name"
    }
}
Get-ChildItem -LiteralPath $bundle | Where-Object { $_.PSIsContainer -or $_.Extension -in '.dll', '.exe' } |
    Copy-Item -Destination $payload -Recurse

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'Could not find the Visual Studio C++ tools' }
$crt = Get-ChildItem -Path (Join-Path $vs 'VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT') -Directory |
    Where-Object { $_.Parent.Parent.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Parent.Parent.Name } -Descending | Select-Object -First 1
if (!$crt) { throw 'Could not find the x64 Visual C++ redistributable files' }
Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' | Copy-Item -Destination $payload

$server = (New-Item -ItemType Directory -Path (Join-Path $payload 'server')).FullName
& tar.exe -xf $mediaArchive -C $server 'mediamtx.exe' 'LICENSE'
if ($LASTEXITCODE -ne 0) { throw 'MediaMTX extraction failed' }

Copy-Item -LiteralPath (Join-Path $root 'LICENSE'), (Join-Path $root 'THIRD-PARTY.md') -Destination $payload
$notices = (New-Item -ItemType Directory -Path (Join-Path $payload 'licenses')).FullName
Copy-Item -LiteralPath (Join-Path $root 'licenses/LGPL-2.1.txt') -Destination $notices
foreach ($dependency in @('libmpv', 'ANGLE')) {
    Get-ChildItem -LiteralPath (Join-Path $build $dependency) -File |
        Where-Object { $_.Name -match '^(license|copying|copyright|notice)' } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $notices "$dependency-$($_.Name)")
        }
}

$msi = Join-Path $output "RTMP-Live-Desk-Setup-$version-win-x64.msi"
$icon = Join-Path $root 'windows/runner/resources/app_icon.ico'
$previousRollForward = $env:DOTNET_ROLL_FORWARD
try {
    $env:DOTNET_ROLL_FORWARD = 'LatestMajor'
    & $Wix build (Join-Path $root 'packaging/RtmpLiveDesk.wxs') -arch x64 `
        -d "PayloadDir=$payload" -d "AppVersion=$version" -d "IconFile=$icon" -pdbtype none -o $msi
    if ($LASTEXITCODE -ne 0) { throw 'MSI build failed' }
}
finally {
    $env:DOTNET_ROLL_FORWARD = $previousRollForward
}

Write-Output $msi
