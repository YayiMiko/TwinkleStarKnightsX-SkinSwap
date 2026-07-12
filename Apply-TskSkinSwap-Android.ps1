[CmdletBinding()]
param(
    [string[]]$CharacterId,
    [switch]$DryRun,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$toolRoot = $PSScriptRoot
$toolsRoot = Join-Path $toolRoot '.tools\android-installer'
$pythonRoot = Join-Path $toolsRoot 'python'
$pythonExe = Join-Path $pythonRoot 'python.exe'
$platformToolsRoot = Join-Path $toolsRoot 'platform-tools'
$adbExe = Join-Path $platformToolsRoot 'adb.exe'
$installer = Join-Path $toolRoot 'android\installer.py'
$releaseRuntime = Join-Path $toolRoot 'android\runtime\tskskinswap.js'
$developmentRuntime = Join-Path $toolRoot 'android\dist\tskskinswap.js'
$runtime = if (Test-Path $releaseRuntime) { $releaseRuntime } else { $developmentRuntime }

function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
}

New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null

if (-not (Test-Path $adbExe)) {
    $developmentAdb = Join-Path $toolRoot '.tools\android\platform-tools\adb.exe'
    $systemAdb = Get-Command adb.exe -ErrorAction SilentlyContinue
    if (Test-Path $developmentAdb) {
        $adbExe = $developmentAdb
    } elseif ($systemAdb) {
        $adbExe = $systemAdb.Source
    } else {
        $platformToolsZip = Join-Path $toolsRoot 'platform-tools-latest-windows.zip'
        if (-not (Test-Path $platformToolsZip)) {
            Get-RemoteFile `
                -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
                -Destination $platformToolsZip
        }
        Expand-Archive -LiteralPath $platformToolsZip -DestinationPath $toolsRoot -Force
    }
}

if (-not (Test-Path $pythonExe)) {
    $pythonZip = Join-Path $toolsRoot 'python-3.12.10-embed-amd64.zip'
    if (-not (Test-Path $pythonZip)) {
        Get-RemoteFile `
            -Uri 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' `
            -Destination $pythonZip
    }
    New-Item -ItemType Directory -Force -Path $pythonRoot | Out-Null
    Expand-Archive -LiteralPath $pythonZip -DestinationPath $pythonRoot -Force
}

if (-not (Test-Path $runtime)) {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        throw 'Compiled Android runtime is missing. Use a release package or install Node.js to build from source.'
    }
    Push-Location (Join-Path $toolRoot 'android')
    try {
        & $npm.Source install
        if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' }
        & $npm.Source run build
        if ($LASTEXITCODE -ne 0) { throw 'Android runtime build failed.' }
    } finally {
        Pop-Location
    }
}

$arguments = @(
    $installer,
    '--adb', $adbExe,
    '--script', $runtime,
    '--output-dir', (Join-Path $toolRoot 'downloaded\android')
)
foreach ($id in $CharacterId) {
    $arguments += @('--character-id', $id)
}
if ($DryRun) { $arguments += '--dry-run' }
if ($NoRestart) { $arguments += '--no-restart' }

& $pythonExe @arguments
exit $LASTEXITCODE
