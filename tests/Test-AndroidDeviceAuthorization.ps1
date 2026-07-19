$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "TskSkinSwap-adb-$([Guid]::NewGuid().ToString('N'))"

try {
    . (Join-Path $repositoryRoot 'Android-Tools.ps1')

    $parsed = @(ConvertFrom-TskAdbDevicesOutput -Output @(
        'List of devices attached',
        'SERIAL-A unauthorized',
        'SERIAL-B device',
        '* daemon started successfully'
    ))
    if ($parsed.Count -ne 2 -or
        $parsed[0].Serial -ne 'SERIAL-A' -or
        $parsed[0].State -ne 'unauthorized' -or
        $parsed[1].Serial -ne 'SERIAL-B' -or
        $parsed[1].State -ne 'device') {
        throw 'ADB device output was parsed incorrectly.'
    }

    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $fakeAdb = Join-Path $testRoot 'adb.cmd'
    @(
        '@echo off',
        'echo * daemon not running; starting now at tcp:5037 1>&2',
        'echo List of devices attached',
        'echo TEST-PHONE unauthorized',
        'exit /b 0'
    ) | Set-Content -LiteralPath $fakeAdb -Encoding ASCII

    $devices = @(Get-TskAdbDevices -AdbExe $fakeAdb)
    if ($devices.Count -ne 1 -or
        $devices[0].Serial -ne 'TEST-PHONE' -or
        $devices[0].State -ne 'unauthorized') {
        throw 'ADB stderr handling lost the unauthorized device state.'
    }

    try {
        [void](Wait-TskAuthorizedAndroidDevice -AdbExe $fakeAdb -TimeoutSeconds 0)
        throw 'An unauthorized device was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'USB debugging was not authorized') {
            throw
        }
    }

    $unicodeRoot = Join-Path $testRoot ([string][char]0x6D4B + [char]0x8BD5)
    $asciiRoot = Join-Path $testRoot 'ascii-temp'
    $asciiTemporary = New-TskAsciiTemporaryDirectory `
        -Prefix 'AndroidApkTest' `
        -CandidateRoot @($unicodeRoot, $asciiRoot)
    try {
        if ($asciiTemporary -match '[^\x00-\x7F]' -or
            -not $asciiTemporary.StartsWith($asciiRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path $asciiTemporary)) {
            throw 'An ASCII-only temporary directory was not selected.'
        }
    } finally {
        Remove-Item -LiteralPath $asciiTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($entryScript in @(
        'Apply-TskSkinSwap-Android.ps1',
        'Uninstall-TskSkinSwap-Android.ps1'
    )) {
        $content = Get-Content -Raw -Encoding UTF8 (Join-Path $repositoryRoot $entryScript)
        if ($content -match 'get-state' -or
            $content -notmatch 'Wait-TskAuthorizedAndroidDevice') {
            throw "$entryScript does not use the shared authorization check."
        }
    }
    $builder = Get-Content -Raw -Encoding UTF8 (Join-Path $repositoryRoot 'Build-TskSkinSwap-AndroidApk.ps1')
    if ($builder -match 'Join-Path \(\[IO\.Path\]::GetTempPath\(\)\)' -or
        $builder -notmatch 'New-TskAsciiTemporaryDirectory') {
        throw 'The Android APK builder does not use an ASCII-safe staging directory.'
    }

    Write-Host 'Android device authorization tests passed.'
} finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
