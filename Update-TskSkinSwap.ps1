[CmdletBinding()]
param(
    [string]$GamePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [ValidateSet('HighQuality', 'LowQuality')]
    [string]$Quality = 'HighQuality',
    [ValidateSet('adult', 'general')]
    [string]$Edition = 'adult',
    [switch]$DryRun,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$toolRoot = $PSScriptRoot
$toolsRoot = Join-Path $toolRoot '.tools'
$outputRoot = Join-Path $toolRoot 'generated'
$downloadRoot = Join-Path $toolRoot 'downloaded\bundles'
$cacheRoot = Join-Path $env:USERPROFILE 'AppData\LocalLow\Unity\FANZAGAMES_twinkle_starknightsX'
$catalogPath = Join-Path $env:USERPROFILE 'AppData\LocalLow\FANZAGAMES\twinkle_starknightsX\com.unity.addressables\catalog_0.0.0.json'
$pluginConfigRoot = Join-Path $GamePath 'BepInEx\config\TskSkinSwap'
$bepInExCore = Join-Path $GamePath 'BepInEx\core\BepInEx.Unity.IL2CPP.dll'
$bepInExZip = Join-Path $toolsRoot 'BepInEx-Unity.IL2CPP-win-x64-6.0.0-pre.2.zip'
$bepInExUrl = 'https://github.com/BepInEx/BepInEx/releases/download/v6.0.0-pre.2/BepInEx-Unity.IL2CPP-win-x64-6.0.0-pre.2.zip'
$localDotnet = Join-Path $toolsRoot 'dotnet\dotnet.exe'
$dotnetInstaller = Join-Path $toolsRoot 'dotnet-install.ps1'
$pythonDirectory = Join-Path $toolsRoot 'python'
$localPython = Join-Path $pythonDirectory 'python.exe'
$pythonZip = Join-Path $toolsRoot 'python-3.12.10-embed-amd64.zip'
$pythonUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
$getPip = Join-Path $toolsRoot 'get-pip.py'

function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
}

function Stop-StartedGameProcesses {
    param([datetime]$StartedAfter)

    Get-Process twinkle_starknightsX -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -ge $StartedAfter } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Test-LocalPythonModule {
    param([Parameter(Mandatory = $true)][string]$Module)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $localPython -c "import $Module" *> $null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Invoke-LocalPython {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $localPython @Arguments
        $script:LocalPythonExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Initialize-InteropAssemblies {
    param([string]$InteropPath)

    Write-Host 'Generating IL2CPP interop assemblies...'
    $startedAt = Get-Date
    $logPath = Join-Path $GamePath 'BepInEx\LogOutput.log'
    $previousLogWrite = if (Test-Path $logPath) { (Get-Item $logPath).LastWriteTimeUtc } else { [datetime]::MinValue }
    $process = Start-Process -FilePath (Join-Path $GamePath 'twinkle_starknightsX.exe') `
        -WorkingDirectory $GamePath -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(180)
    $startupComplete = $false
    do {
        Start-Sleep -Seconds 1
        if ((Test-Path $logPath) -and ((Get-Item $logPath).LastWriteTimeUtc -gt $previousLogWrite)) {
            try {
                $startupComplete = (Get-Content $logPath -Raw) -match 'Chainloader startup complete'
            } catch {
                $startupComplete = $false
            }
        }
    } while (-not $startupComplete -and -not $process.HasExited -and (Get-Date) -lt $deadline)

    Stop-StartedGameProcesses -StartedAfter $startedAt
    if (-not (Test-Path $InteropPath)) {
        throw 'BepInEx did not generate IL2CPP interop assemblies.'
    }
    if (-not $startupComplete) {
        throw "BepInEx did not finish validating the IL2CPP interop assemblies. Check $logPath"
    }
}

function Initialize-LocalPython {
    New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
    if (-not (Test-Path $localPython)) {
        if (-not (Test-Path $pythonZip)) {
            Get-RemoteFile -Uri $pythonUrl -Destination $pythonZip
        }
        New-Item -ItemType Directory -Force -Path $pythonDirectory | Out-Null
        Expand-Archive -LiteralPath $pythonZip -DestinationPath $pythonDirectory -Force

        $pthFile = Get-ChildItem $pythonDirectory -Filter 'python*._pth' | Select-Object -First 1
        if (-not $pthFile) {
            throw 'Embedded Python path configuration was not found.'
        }
        $pth = Get-Content $pthFile.FullName
        $pth = $pth -replace '^#import site$', 'import site'
        Set-Content -LiteralPath $pthFile.FullName -Value $pth -Encoding ASCII
    }

    if (-not (Test-LocalPythonModule -Module 'pip')) {
        if (-not (Test-Path $getPip)) {
            Get-RemoteFile -Uri 'https://bootstrap.pypa.io/get-pip.py' -Destination $getPip
        }
        Invoke-LocalPython -Arguments @($getPip, '--no-warn-script-location')
        if ($script:LocalPythonExitCode -ne 0) {
            throw 'Unable to bootstrap pip for embedded Python.'
        }
    }

    if (-not (Test-LocalPythonModule -Module 'UnityPy')) {
        Write-Host 'Installing UnityPy into the local tool environment...'
        Invoke-LocalPython -Arguments @('-m', 'pip', 'install', 'UnityPy', '--disable-pip-version-check', '--no-warn-script-location')
        if ($script:LocalPythonExitCode -ne 0) {
            throw 'Unable to install UnityPy.'
        }
    }
}

if (-not (Test-Path (Join-Path $GamePath 'GameAssembly.dll'))) {
    throw "GameAssembly.dll was not found under $GamePath"
}

if (Get-Process twinkle_starknightsX -ErrorAction SilentlyContinue) {
    throw 'The game is running. Close it before applying TskSkinSwap.'
}

New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null

if (-not (Test-Path $bepInExCore)) {
    if (-not (Test-Path $bepInExZip)) {
        Get-RemoteFile -Uri $bepInExUrl -Destination $bepInExZip
    }
    Write-Host 'Installing BepInEx IL2CPP...'
    Expand-Archive -LiteralPath $bepInExZip -DestinationPath $GamePath -Force
}

if (-not (Test-Path $localDotnet)) {
    if (-not (Test-Path $dotnetInstaller)) {
        Get-RemoteFile -Uri 'https://dot.net/v1/dotnet-install.ps1' -Destination $dotnetInstaller
    }
    Write-Host 'Installing the local .NET 6 SDK...'
    & $dotnetInstaller -Channel 6.0 -InstallDir (Join-Path $toolsRoot 'dotnet') -NoPath
    if (-not (Test-Path $localDotnet)) {
        throw 'The local .NET SDK installation failed.'
    }
}

$interopAssembly = Join-Path $GamePath 'BepInEx\interop\spine-unity.dll'
$currentGameHash = (Get-FileHash (Join-Path $GamePath 'GameAssembly.dll') -Algorithm SHA256).Hash
$installedMapping = Join-Path $pluginConfigRoot 'mappings.json'
$previousGameHash = $null
if (Test-Path $installedMapping) {
    try {
        $previousGameHash = (Get-Content $installedMapping -Raw | ConvertFrom-Json).gameAssemblySha256
    } catch {
        $previousGameHash = $null
    }
}
$gameChanged = $previousGameHash -and ($previousGameHash -ne $currentGameHash)
if (-not (Test-Path $interopAssembly) -or $gameChanged) {
    Initialize-InteropAssemblies -InteropPath $interopAssembly
}

Initialize-LocalPython

if (-not (Test-Path $catalogPath)) {
    throw "The current Addressables catalog was not found: $catalogPath. Start the game once after updating, then close it and retry."
}

Write-Host 'Resolving and downloading high-quality transformation and Cutin bundles...'
$downloaderArgs = @(
    (Join-Path $toolRoot 'catalog_downloader.py'),
    '--catalog', $catalogPath,
    '--output-dir', $downloadRoot,
    '--quality', $Quality,
    '--edition', $Edition
)
if ($DryRun) {
    $downloaderArgs += '--dry-run'
}
Invoke-LocalPython -Arguments $downloaderArgs
if ($script:LocalPythonExitCode -ne 0) {
    throw "Bundle download failed with exit code $script:LocalPythonExitCode"
}

Write-Host 'Scanning cached high-quality Spine assets...'
$scannerArgs = @(
    (Join-Path $toolRoot 'scanner.py'),
    '--game-dir', $GamePath,
    '--cache-dir', $cacheRoot,
    '--bundle-dir', $downloadRoot,
    '--output-dir', $outputRoot,
    '--quality', $Quality,
    '--edition', $Edition
)
if ($DryRun) {
    $scannerArgs += '--dry-run'
}

Invoke-LocalPython -Arguments $scannerArgs
if ($script:LocalPythonExitCode -ne 0) {
    throw "Asset scan failed with exit code $script:LocalPythonExitCode"
}
if ($DryRun) {
    return
}

New-Item -ItemType Directory -Force -Path $pluginConfigRoot | Out-Null
Copy-Item (Join-Path $outputRoot 'mappings.json') $pluginConfigRoot -Force
$atlasTarget = Join-Path $pluginConfigRoot 'atlases'
New-Item -ItemType Directory -Force -Path $atlasTarget | Out-Null
$atlasFiles = Get-ChildItem (Join-Path $outputRoot 'atlases') -File -ErrorAction SilentlyContinue
if ($atlasFiles) {
    Copy-Item $atlasFiles.FullName $atlasTarget -Force
}

if (-not $SkipBuild) {
    & (Join-Path $toolRoot 'Build-TskSkinSwap.ps1') -GamePath $GamePath
}

Write-Host "Generated mapping: $(Join-Path $pluginConfigRoot 'mappings.json')"
