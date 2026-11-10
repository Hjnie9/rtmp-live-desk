param(
    [string]$Flutter = 'flutter.bat',
    [string]$Wix = 'wix.exe',
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant(),
    [string]$CacheDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$hostArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ($hostArch -ne $Architecture) { throw "Flutter Windows requires a native $Architecture build host" }
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

$build = Join-Path $root "build/windows/$Architecture"
$bundle = Join-Path $build 'runner/Release'
foreach ($name in @('rtmp_live_desk.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so')) {
    if (!(Test-Path -LiteralPath (Join-Path $bundle $name) -PathType Leaf)) {
        throw "The Windows $Architecture bundle is missing $name"
    }
}
Get-ChildItem -LiteralPath $bundle | Where-Object { $_.PSIsContainer -or $_.Extension -in '.dll', '.exe', '.json' } |
    Copy-Item -Destination $payload -Recurse

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vcComponent = if ($Architecture -eq 'arm64') {
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
} else {
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
}
$vs = & $vswhere -latest -products '*' -requires $vcComponent -property installationPath
if (!$vs) { throw 'Could not find the Visual Studio C++ tools' }
$crt = Get-ChildItem -Path (Join-Path $vs "VC/Redist/MSVC/*/$Architecture/Microsoft.VC*.CRT") -Directory |
    Where-Object { $_.Parent.Parent.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Parent.Parent.Name } -Descending | Select-Object -First 1
if (!$crt) { throw "Could not find the $Architecture Visual C++ redistributable files" }

$server = (New-Item -ItemType Directory -Path (Join-Path $payload 'server')).FullName
if ($Architecture -eq 'x64') {
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
    & tar.exe -xf $mediaArchive -C $server 'mediamtx.exe' 'LICENSE'
    if ($LASTEXITCODE -ne 0) { throw 'MediaMTX extraction failed' }
} else {
    $source = Join-Path $stage 'mediamtx'
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$mediaVersion" `
        'https://github.com/bluenviron/mediamtx.git' $source
    if ($LASTEXITCODE -ne 0 -or (git -C $source rev-parse HEAD) -ne '9540cb6c1d9f1e9351fcc4ded3afc249ffff22bc') {
        throw 'Could not restore the pinned MediaMTX source'
    }
    Push-Location -LiteralPath $source
    $previousCgo = $env:CGO_ENABLED
    $previousGoOs = $env:GOOS
    $previousGoArch = $env:GOARCH
    try {
        $env:CGO_ENABLED = '0'
        $env:GOOS = 'windows'
        $env:GOARCH = 'arm64'
        Set-Content -LiteralPath 'internal/core/VERSION' -Value "v$mediaVersion" -Encoding ascii -NoNewline
        & go.exe generate ./internal/servers/hls
        if ($LASTEXITCODE -ne 0) { throw 'MediaMTX resource generation failed' }
        & go.exe build -mod=readonly -trimpath -buildvcs=false -o (Join-Path $server 'mediamtx.exe') .
        if ($LASTEXITCODE -ne 0) { throw 'MediaMTX ARM64 build failed' }
        Copy-Item -LiteralPath 'LICENSE' -Destination $server
    }
    finally {
        $env:CGO_ENABLED = $previousCgo
        $env:GOOS = $previousGoOs
        $env:GOARCH = $previousGoArch
        Pop-Location
    }
}

$machine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
Get-ChildItem -LiteralPath $payload -Recurse -File | Where-Object { $_.Extension -in '.dll', '.exe' } | ForEach-Object {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($_.FullName))
    try {
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne $machine) {
            throw "$($_.Name) does not match the requested $Architecture machine type"
        }
    }
    finally {
        $reader.Dispose()
    }
}

# Use the compiler's architecture-specific redistributable as shipped.
# Microsoft can include hybrid ARM64X DLLs in its ARM64 CRT directory.
Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' | Copy-Item -Destination $payload

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
$angleNotices = Join-Path $build 'ANGLE/LICENSES'
if (Test-Path -LiteralPath $angleNotices -PathType Container) {
    Copy-Item -LiteralPath $angleNotices -Destination (Join-Path $notices 'ANGLE') -Recurse
}

$msi = Join-Path $output "RTMP-Live-Desk-Setup-$version-win-$Architecture.msi"
$icon = Join-Path $root 'windows/runner/resources/app_icon.ico'
$previousRollForward = $env:DOTNET_ROLL_FORWARD
Push-Location -LiteralPath $stage
try {
    $env:DOTNET_ROLL_FORWARD = 'LatestMajor'
    & $Wix extension add 'WixToolset.UI.wixext/6.0.2'
    if ($LASTEXITCODE -ne 0) { throw 'WiX UI extension installation failed' }
    & $Wix build (Join-Path $root 'packaging/RtmpLiveDesk.wxs') (Join-Path $root 'packaging/DeskSetup.wxs') `
        -arch $Architecture -ext 'WixToolset.UI.wixext/6.0.2' `
        -d "PayloadDir=$payload" -d "AppVersion=$version" -d "IconFile=$icon" -pdbtype none -o $msi
    if ($LASTEXITCODE -ne 0) { throw 'MSI build failed' }
}
finally {
    $env:DOTNET_ROLL_FORWARD = $previousRollForward
    Pop-Location
}

Write-Output $msi
