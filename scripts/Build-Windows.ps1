param(
    [string]$Dotnet = 'dotnet.exe',
    [string]$Wix = 'wix.exe',
    [string]$CacheDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$projectFile = Join-Path $root 'src/RtmpLiveDesk/RtmpLiveDesk.csproj'
[xml]$project = Get-Content -LiteralPath $projectFile -Raw
$version = $project.Project.PropertyGroup.Version
$icon = Join-Path $root 'src/RtmpLiveDesk/Assets/App.ico'
$artifacts = Join-Path $root 'artifacts'
if (!$CacheDirectory) { $CacheDirectory = Join-Path $artifacts 'cache' }
if (!$OutputDirectory) { $OutputDirectory = $artifacts }
$cache = (New-Item -ItemType Directory -Force -Path $CacheDirectory).FullName
$output = (New-Item -ItemType Directory -Force -Path $OutputDirectory).FullName
$stage = (New-Item -ItemType Directory -Force -Path (Join-Path $artifacts ('build-' + [Guid]::NewGuid().ToString('N')))).FullName
$payload = Join-Path $stage 'publish'
$nuget = Join-Path $cache 'nuget'

function Get-Archive([string]$Name, [string]$Url, [string]$Sha256) {
    $path = Join-Path $cache $Name
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Sha256) {
        & curl.exe --fail --silent --show-error --location --retry 2 --max-time 120 -o $path $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed for $Name" }
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Sha256) {
        throw "SHA-256 mismatch for $Name"
    }
    return $path
}

$mediaArchive = Get-Archive 'mediamtx_v1.21.3_windows_amd64.zip' `
    'https://github.com/bluenviron/mediamtx/releases/download/v1.21.3/mediamtx_v1.21.3_windows_amd64.zip' `
    'b2f5246b07cb72961df03b8d5e8cad43dc657bcf3f49a87bb031bdf22721af74'
$vlcArchive = Get-Archive 'vlc-3.0.24-win64.zip' `
    'https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/vlc-3.0.24-win64.zip' `
    'fcf30850371ad10c9373cc4f0f4501e7dee49e3e9ae9f20c72fb2661a1ca6323'

& $Dotnet publish $projectFile -c Release -r win-x64 `
    --self-contained true --source 'https://api.nuget.org/v3/index.json' "-p:RestorePackagesPath=$nuget" `
    -p:DebugType=None -p:DebugSymbols=false -o $payload
if ($LASTEXITCODE -ne 0) { throw 'Desktop publish failed' }

$serverDirectory = (New-Item -ItemType Directory -Path (Join-Path $payload 'server')).FullName
& tar.exe -xf $mediaArchive -C $serverDirectory 'mediamtx.exe' 'LICENSE'
if ($LASTEXITCODE -ne 0) { throw 'MediaMTX extraction failed' }

& tar.exe -xf $vlcArchive -C $stage 'vlc-3.0.24/libvlc.dll' 'vlc-3.0.24/libvlccore.dll' 'vlc-3.0.24/plugins' 'vlc-3.0.24/COPYING.txt'
if ($LASTEXITCODE -ne 0) { throw 'VLC extraction failed' }
$vlcDirectory = (New-Item -ItemType Directory -Path (Join-Path $payload 'vlc')).FullName
Copy-Item -LiteralPath (Join-Path $stage 'vlc-3.0.24/libvlc.dll'), (Join-Path $stage 'vlc-3.0.24/libvlccore.dll'), `
    (Join-Path $stage 'vlc-3.0.24/COPYING.txt'), (Join-Path $stage 'vlc-3.0.24/plugins') -Destination $vlcDirectory -Recurse
Copy-Item -LiteralPath (Join-Path $root 'LICENSE'), (Join-Path $root 'THIRD-PARTY.md') -Destination $payload
$notices = (New-Item -ItemType Directory -Path (Join-Path $payload 'licenses')).FullName
Copy-Item -LiteralPath (Join-Path $root 'licenses/LGPL-2.1.txt') -Destination $notices
$netRuntime = Join-Path $nuget 'microsoft.netcore.app.runtime.win-x64/10.0.14'
$desktopRuntime = Join-Path $nuget 'microsoft.windowsdesktop.app.runtime.win-x64/10.0.14'
Copy-Item -LiteralPath (Join-Path $netRuntime 'LICENSE.TXT') -Destination (Join-Path $notices 'dotnet-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $netRuntime 'THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $notices 'dotnet-THIRD-PARTY-NOTICES.txt')
Copy-Item -LiteralPath (Join-Path $desktopRuntime 'LICENSE') -Destination (Join-Path $notices 'windowsdesktop-LICENSE.txt')

$msi = Join-Path $output "RTMP-Live-Desk-$version-win-x64.msi"
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
