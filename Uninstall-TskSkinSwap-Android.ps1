[CmdletBinding()]
param(
    [string]$Package = 'jp.co.fanzagames.twinklestarknightsx_a_mod',
    [switch]$RemoveBundles,
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

if ($Package -notmatch '^[A-Za-z0-9._]+$') {
    throw 'Invalid Android package name.'
}
$adbExe = Get-TskAndroidAdb -ToolRoot $toolRoot

if ((& $adbExe get-state 2>$null) -ne 'device') {
    throw 'No authorized Android device is connected. Unlock the phone and allow USB debugging.'
}
$devices = @(& $adbExe devices | Select-String -Pattern "\tdevice$")
if ($devices.Count -ne 1) {
    throw "Exactly one authorized Android device is required; found $($devices.Count)."
}
if (-not ((& $adbExe shell pm path $Package 2>$null) -like 'package:*')) {
    throw "Android package is not installed: $Package"
}

$packageDetails = & $adbExe shell dumpsys package $Package
$versionCodeLine = $packageDetails | Where-Object { $_ -match '^\s*versionCode=(\d+)' } | Select-Object -First 1
if (-not $versionCodeLine) {
    throw 'Unable to read the installed Android package version.'
}
[void]($versionCodeLine -match '^\s*versionCode=(\d+)')
$installedVersionCode = $Matches[1]
$pythonExe = Get-TskAndroidPython -ToolRoot $toolRoot
$source = Get-TskCompatibleSourceApk -ToolRoot $toolRoot -PythonExe $pythonExe
$metadata = $source.Metadata
$sourceApk = $source.Path
if ($installedVersionCode -ne [string]$metadata.versionCode) {
    throw 'The compatible APK does not match the installed game version. Use a TskSkinSwap package that supports the installed version.'
}

$filesRoot = "/sdcard/Android/data/$Package/files"
$modRoot = "$filesRoot/tskskinswap"
& $adbExe shell am force-stop $Package | Out-Null
& $adbExe install -r $sourceApk
if ($LASTEXITCODE -ne 0) {
    throw 'ADB refused the original compatible APK. The installed app was not uninstalled.'
}
& $adbExe shell "rm -f '$filesRoot/frida-scripts/tskskinswap.js' '$modRoot/mappings.json' '$modRoot/runtime.log'" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the Android runtime files.' }

if ($RemoveBundles) {
    & $adbExe shell "rm -rf '$modRoot/bundles'" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the downloaded Android bundles.' }
    Write-Host 'The compatible APK was restored and downloaded transform bundles were removed.'
} else {
    Write-Host 'The compatible APK was restored. Downloaded transform bundles were kept for reuse.'
}

if (-not $NoRestart) {
    & $adbExe shell "monkey -p $Package -c android.intent.category.LAUNCHER 1 >/dev/null" | Out-Null
    Start-Sleep -Seconds 2
    $gamePid = (& $adbExe shell pidof $Package).Trim()
    if (-not $gamePid) {
        throw 'Restore finished, but the game did not start on the phone.'
    }
}
