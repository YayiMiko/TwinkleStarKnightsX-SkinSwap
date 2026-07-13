[CmdletBinding()]
param(
    [string[]]$CharacterId,
    [string]$SourceApk,
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
$apkSource = Join-Path $toolRoot 'android\apk_source.py'
$apkBuilder = Join-Path $toolRoot 'Build-TskSkinSwap-AndroidApk.ps1'
$apkCache = Join-Path $toolsRoot 'apk'
$supportedApkManifest = Join-Path $toolRoot 'android\supported_apks.json'
$patchedApk = Join-Path $toolRoot '.tools\android-output\TskSkinSwap-Android-current-patched.apk'
$releaseRuntime = Join-Path $toolRoot 'android\runtime\tskskinswap.js'
$developmentRuntime = Join-Path $toolRoot 'android\dist\tskskinswap.js'
$runtime = if (Test-Path $releaseRuntime) { $releaseRuntime } else { $developmentRuntime }
$platformToolsVersion = '37.0.0'
$platformToolsHash = '4fe305812db074cea32903a489d061eb4454cbc90a49e8fea677f4b7af764918'
$pythonHash = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'

function Get-VerifiedRemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    if (Test-Path $Destination) {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -eq $ExpectedHash) { return }
        Remove-Item -LiteralPath $Destination -Force
    }
    $temporary = "$Destination.part"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Write-Host "Downloading $Uri"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary
        $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $ExpectedHash) {
            throw "Downloaded file failed SHA-256 validation: $Uri"
        }
        Move-Item -LiteralPath $temporary -Destination $Destination
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
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
        $platformToolsZip = Join-Path $toolsRoot "platform-tools-$platformToolsVersion-windows.zip"
        Get-VerifiedRemoteFile `
            -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
            -Destination $platformToolsZip `
            -ExpectedHash $platformToolsHash
        if (Test-Path $platformToolsRoot) {
            Remove-Item -LiteralPath $platformToolsRoot -Recurse -Force
        }
        Expand-Archive -LiteralPath $platformToolsZip -DestinationPath $toolsRoot -Force
        $sourceProperties = Join-Path $platformToolsRoot 'source.properties'
        if (-not (Test-Path $adbExe) -or
            -not ((Get-Content -Raw -LiteralPath $sourceProperties) -match "Pkg.Revision=$([regex]::Escape($platformToolsVersion))")) {
            throw 'Android Platform Tools extraction failed version validation.'
        }
    }
}

if (-not (Test-Path $pythonExe)) {
    $pythonZip = Join-Path $toolsRoot 'python-3.12.10-embed-amd64.zip'
    Get-VerifiedRemoteFile `
        -Uri 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' `
        -Destination $pythonZip `
        -ExpectedHash $pythonHash
    if (Test-Path $pythonRoot) {
        Remove-Item -LiteralPath $pythonRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $pythonRoot | Out-Null
    Expand-Archive -LiteralPath $pythonZip -DestinationPath $pythonRoot -Force
    if (-not (Test-Path $pythonExe)) {
        throw 'Portable Python extraction failed.'
    }
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

if ((& $adbExe get-state 2>$null) -ne 'device') {
    throw 'No authorized Android device is connected. Unlock the phone and allow USB debugging.'
}
$devices = @(& $adbExe devices | Select-String -Pattern "\tdevice$")
if ($devices.Count -ne 1) {
    throw "Exactly one authorized Android device is required; found $($devices.Count)."
}
$package = 'jp.co.fanzagames.twinklestarknightsx_a_mod'
if (-not ((& $adbExe shell pm path $package 2>$null) -like 'package:*')) {
    throw 'Install and launch the compatible Android package (APK) once before applying this MOD.'
}
$catalog = "/sdcard/Android/data/$package/files/com.unity.addressables/catalog_0.0.0.json"
$catalogReady = & $adbExe shell "if [ -f '$catalog' ]; then echo READY; fi"
if ($catalogReady -ne 'READY') {
    throw 'Launch the game on the phone, finish its initial data download, close it, and run this BAT again.'
}

if (-not $DryRun) {
    if ($SourceApk) {
        $resolvedSourceApk = (Resolve-Path $SourceApk).Path
    } else {
        New-Item -ItemType Directory -Force -Path $apkCache | Out-Null
        & $pythonExe $apkSource --output-dir $apkCache | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Compatible APK download failed.' }
        $sourceMetadata = Get-Content -Raw -LiteralPath (Join-Path $apkCache 'source-apk.json') |
            ConvertFrom-Json
        if ($sourceMetadata.schemaVersion -ne 1 -or
            $sourceMetadata.assetName -notmatch '^Kurusuta-X\.Mod_[0-9.]+_patched\.apk$') {
            throw 'Compatible APK downloader returned invalid metadata.'
        }
        $resolvedSourceApk = Join-Path $apkCache $sourceMetadata.assetName
        if (-not (Test-Path $resolvedSourceApk)) {
            throw 'Compatible APK downloader did not return a valid file.'
        }
    }
    $sourceHash = (Get-FileHash -LiteralPath $resolvedSourceApk -Algorithm SHA256).Hash.ToLowerInvariant()
    $supportedDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $supportedApkManifest | ConvertFrom-Json
    $supportedMatches = @($supportedDocument.apks | Where-Object { $_.sha256 -eq $sourceHash })
    if ($supportedDocument.schemaVersion -ne 1 -or $supportedMatches.Count -ne 1) {
        throw "The complete APK SHA-256 is not supported: $sourceHash"
    }
    $targetPackageVersion = [string]$supportedMatches[0].versionName
    & $apkBuilder `
        -InputApk $resolvedSourceApk `
        -OutputApk $patchedApk `
        -RuntimeScript $runtime `
        -SkipRuntimeBuild `
        -Adb $adbExe
    if ($LASTEXITCODE -ne 0) { throw 'Compatible APK patching or installation failed.' }
    & $adbExe shell am force-stop $package | Out-Null
}

$arguments = @(
    $installer,
    '--adb', $adbExe,
    '--embedded-runtime',
    '--output-dir', (Join-Path $toolRoot 'downloaded\android')
)
foreach ($id in $CharacterId) {
    $arguments += @('--character-id', $id)
}
if ($DryRun) { $arguments += '--dry-run' }
if (-not $DryRun) {
    $arguments += @('--package-version-name', $targetPackageVersion, '--no-restart')
} elseif ($NoRestart) {
    $arguments += '--no-restart'
}

& $pythonExe @arguments
$installerExitCode = $LASTEXITCODE
if ($installerExitCode -ne 0 -or $DryRun) {
    exit $installerExitCode
}

& $adbExe install -r $patchedApk
if ($LASTEXITCODE -ne 0) {
    throw 'ADB refused the patched APK. The existing app was not uninstalled.'
}
if (-not $NoRestart) {
    & $adbExe shell "monkey -p $package -c android.intent.category.LAUNCHER 1 >/dev/null" | Out-Null
    Start-Sleep -Seconds 2
    $gamePid = (& $adbExe shell pidof $package).Trim()
    if (-not $gamePid) {
        throw 'Installation finished, but the game did not start on the phone.'
    }
}
Write-Host 'Android MOD installation completed without clearing application data.'
