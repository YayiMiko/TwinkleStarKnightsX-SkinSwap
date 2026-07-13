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
$commonTools = Join-Path $toolRoot 'Android-Tools.ps1'
if (-not (Test-Path $commonTools)) {
    throw 'Android-Tools.ps1 is missing. Extract the entire release ZIP and retry.'
}
. $commonTools

$toolsRoot = Join-Path $toolRoot '.tools\android-installer'
$installer = Join-Path $toolRoot 'android\installer.py'
$apkBuilder = Join-Path $toolRoot 'Build-TskSkinSwap-AndroidApk.ps1'
$apkCache = Join-Path $toolsRoot 'apk'
$supportedApkManifest = Join-Path $toolRoot 'android\supported_apks.json'
$patchedApk = Join-Path $toolRoot '.tools\android-output\TskSkinSwap-Android-current-patched.apk'
$releaseRuntime = Join-Path $toolRoot 'android\runtime\tskskinswap.js'
$developmentRuntime = Join-Path $toolRoot 'android\dist\tskskinswap.js'
$runtime = if (Test-Path $releaseRuntime) { $releaseRuntime } else { $developmentRuntime }
$adbExe = Get-TskAndroidAdb -ToolRoot $toolRoot
$pythonExe = Get-TskAndroidPython -ToolRoot $toolRoot

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
        $source = Get-TskCompatibleSourceApk -ToolRoot $toolRoot -PythonExe $pythonExe
        $resolvedSourceApk = $source.Path
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
