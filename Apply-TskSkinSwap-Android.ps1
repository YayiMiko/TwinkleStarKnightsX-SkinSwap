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

$installer = Join-Path $toolRoot 'android\installer.py'
$apkBuilder = Join-Path $toolRoot 'Build-TskSkinSwap-AndroidApk.ps1'
$patchedApk = Join-Path $toolRoot '.tools\android-output\TskSkinSwap-Android-current-patched.apk'
$releaseRuntime = Join-Path $toolRoot 'android\runtime\tskskinswap.js'
$developmentRuntime = Join-Path $toolRoot 'android\dist\tskskinswap.js'
$runtime = if (Test-Path $releaseRuntime) { $releaseRuntime } else { $developmentRuntime }
$adbExe = Get-TskAndroidAdb -ToolRoot $toolRoot
$pythonExe = Get-TskAndroidPython -ToolRoot $toolRoot
Start-TskAdbServer -AdbExe $adbExe

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

[void](Wait-TskAuthorizedAndroidDevice -AdbExe $adbExe)
$package = 'jp.co.fanzagames.twinklestarknightsx_a_mod'
if (-not ((& $adbExe shell pm path $package 2>$null) -like 'package:*')) {
    throw 'Install and launch the compatible Android package (APK) once before applying this MOD.'
}
$catalog = "/sdcard/Android/data/$package/files/com.unity.addressables/catalog_0.0.0.json"
$catalogReady = & $adbExe shell "if [ -f '$catalog' ]; then echo READY; fi"
if ($catalogReady -ne 'READY') {
    throw 'Launch the game on the phone, finish its initial data download, close it, and run this BAT again.'
}
$packageDetails = & $adbExe shell dumpsys package $package
$versionLine = $packageDetails | Where-Object { $_ -match '^\s*versionName=(\S+)\s*$' } | Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch '^\s*versionName=(\S+)\s*$') {
    throw 'Unable to read the installed Android game version.'
}
$installedPackageVersion = $Matches[1]

function Install-TskPatchedApk {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $adbExe install -r $patchedApk 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        $reason = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "ADB refused the patched APK. The existing app was not uninstalled.`n$reason"
    }
    $output | Write-Host
}

function Start-TskAndroidGame {
    & $adbExe shell "monkey -p $package -c android.intent.category.LAUNCHER 1 >/dev/null" | Out-Null
    Start-Sleep -Seconds 2
    $gamePid = (& $adbExe shell pidof $package).Trim()
    if (-not $gamePid) {
        throw 'Installation finished, but the game did not start on the phone.'
    }
}

if (-not $DryRun) {
    if ($SourceApk) {
        $resolvedSourceApk = (Resolve-Path $SourceApk).Path
        $targetPackageVersion = $installedPackageVersion
    } else {
        $source = Get-TskCompatibleSourceApk `
            -ToolRoot $toolRoot `
            -PythonExe $pythonExe `
            -MinimumVersionName $installedPackageVersion
        $resolvedSourceApk = $source.Path
        $targetPackageVersion = [string]$source.Metadata.versionName
    }
    & $apkBuilder `
        -InputApk $resolvedSourceApk `
        -OutputApk $patchedApk `
        -RuntimeScript $runtime `
        -ExpectedVersionName $targetPackageVersion `
        -SkipRuntimeBuild `
        -Adb $adbExe
    if ($LASTEXITCODE -ne 0) { throw 'Compatible APK patching or installation failed.' }
    [void](Wait-TskAuthorizedAndroidDevice -AdbExe $adbExe)
    & $adbExe shell am force-stop $package | Out-Null

    if ([version]$targetPackageVersion -gt [version]$installedPackageVersion) {
        Install-TskPatchedApk
        Start-TskAndroidGame
        Write-Host ''
        Write-Host 'The compatible Android app was updated to the latest version.'
        Write-Host 'On the phone, finish the in-game update.'
        Write-Host 'Then close the game and run Apply-TskSkinSwap-Android.bat again to finish the MOD.'
        exit 10
    }
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

Install-TskPatchedApk
if (-not $NoRestart) {
    Start-TskAndroidGame
}
Write-Host 'Android MOD installation completed without clearing application data.'
