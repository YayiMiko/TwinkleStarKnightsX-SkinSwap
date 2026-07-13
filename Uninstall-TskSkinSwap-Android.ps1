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

$apkCache = Join-Path $toolRoot '.tools\android-installer\apk'
$metadataPath = Join-Path $apkCache 'source-apk.json'
if (-not (Test-Path $metadataPath)) {
    throw 'The original compatible APK cache is missing. Run the current Android installer once, then retry.'
}
$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
if ($metadata.schemaVersion -ne 1 -or
    $metadata.assetName -notmatch '^Kurusuta-X\.Mod_[0-9.]+_patched\.apk$' -or
    $metadata.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    [string]$metadata.versionCode -notmatch '^\d+$') {
    throw 'The cached compatible APK metadata is invalid.'
}
$sourceApk = Join-Path $apkCache $metadata.assetName
if (-not (Test-Path $sourceApk)) {
    throw 'The cached compatible APK is missing. Run the current Android installer once, then retry.'
}
$sourceHash = (Get-FileHash -LiteralPath $sourceApk -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceHash -ne $metadata.sha256.ToLowerInvariant()) {
    throw 'The cached compatible APK failed SHA-256 validation.'
}
$packageDetails = & $adbExe shell dumpsys package $Package
$versionCodeLine = $packageDetails | Where-Object { $_ -match '^\s*versionCode=(\d+)' } | Select-Object -First 1
if (-not $versionCodeLine) {
    throw 'Unable to read the installed Android package version.'
}
[void]($versionCodeLine -match '^\s*versionCode=(\d+)')
$installedVersionCode = $Matches[1]
if ($installedVersionCode -ne [string]$metadata.versionCode) {
    throw 'The cached compatible APK does not match the installed game version. Apply a current TskSkinSwap package before uninstalling.'
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
}
