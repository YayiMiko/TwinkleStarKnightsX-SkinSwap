[CmdletBinding()]
param(
    [string]$Package = 'jp.co.fanzagames.twinklestarknightsx_a_mod',
    [switch]$RemoveBundles,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$toolRoot = $PSScriptRoot
$adbCandidates = @(
    (Join-Path $toolRoot '.tools\android-installer\platform-tools\adb.exe'),
    (Join-Path $toolRoot '.tools\android\platform-tools\adb.exe')
)
$adbExe = $adbCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $adbExe) {
    $systemAdb = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($systemAdb) { $adbExe = $systemAdb.Source }
}
if (-not $adbExe) {
    throw 'ADB was not found. Run Apply-TskSkinSwap-Android.bat once, then retry.'
}
if ($Package -notmatch '^[A-Za-z0-9._]+$') {
    throw 'Invalid Android package name.'
}

if ((& $adbExe get-state 2>$null) -ne 'device') {
    throw 'No authorized Android device is connected.'
}
if (-not ((& $adbExe shell pm path $Package 2>$null) -like 'package:*')) {
    throw "Android package is not installed: $Package"
}

$filesRoot = "/sdcard/Android/data/$Package/files"
$modRoot = "$filesRoot/tskskinswap"
& $adbExe shell am force-stop $Package | Out-Null
& $adbExe shell "rm -f '$filesRoot/frida-scripts/tskskinswap.js' '$modRoot/mappings.json' '$modRoot/runtime.log'" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the Android runtime files.' }

if ($RemoveBundles) {
    & $adbExe shell "rm -rf '$modRoot/bundles'" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the downloaded Android bundles.' }
    Write-Host 'Android MOD runtime and downloaded transform bundles were removed.'
} else {
    Write-Host 'Android MOD runtime was removed. Downloaded transform bundles were kept for reuse.'
}

if (-not $NoRestart) {
    & $adbExe shell "monkey -p $Package -c android.intent.category.LAUNCHER 1 >/dev/null" | Out-Null
}
