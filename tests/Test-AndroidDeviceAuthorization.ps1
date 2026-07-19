$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "TskSkinSwap-adb-$([Guid]::NewGuid().ToString('N'))"

try {
    . (Join-Path $repositoryRoot 'Android-Tools.ps1')

    $waitingMessage = @(Get-TskAndroidUserMessage `
        -Key 'waitingMissing' `
        -Fallback @('fallback')) -join "`n"
    $actionPhrase = -join (@(0x73B0, 0x5728, 0x8BF7, 0x64CD, 0x4F5C, 0x624B, 0x673A) |
        ForEach-Object { [char]$_ })
    $continuePhrase = -join (@(0x81EA, 0x52A8, 0x7EE7, 0x7EED) |
        ForEach-Object { [char]$_ })
    if ($waitingMessage -notmatch [regex]::Escape($actionPhrase) -or
        $waitingMessage -notmatch [regex]::Escape($continuePhrase)) {
        throw 'The Chinese phone-action prompt is missing or unclear.'
    }

    $parsed = @(ConvertFrom-TskAdbDevicesOutput -Output @(
        'List of devices attached',
        'SERIAL-A unauthorized',
        'SERIAL-B device',
        '* daemon started successfully',
        ''
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
        'if "%1"=="start-server" (',
        '  cd>"%~dp0adb-working-directory.txt"',
        '  exit /b 0',
        ')',
        'echo * daemon not running; starting now at tcp:5037 1>&2',
        'echo List of devices attached',
        'echo TEST-PHONE unauthorized',
        'echo.',
        'exit /b 0'
    ) | Set-Content -LiteralPath $fakeAdb -Encoding ASCII

    Start-TskAdbServer -AdbExe $fakeAdb
    $adbWorkingDirectory = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'adb-working-directory.txt')
    $releaseRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($adbWorkingDirectory.Trim()).StartsWith(
        $releaseRoot,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ADB was started with the release folder as its working directory.'
    }

    $devices = @(Get-TskAdbDevices -AdbExe $fakeAdb)
    if ($devices.Count -ne 1 -or
        $devices[0].Serial -ne 'TEST-PHONE' -or
        $devices[0].State -ne 'unauthorized') {
        throw 'ADB stderr handling lost the unauthorized device state.'
    }

    $expectedUnauthorizedError = (Get-TskAndroidUserMessage `
        -Key 'errorUnauthorized' `
        -Fallback @('USB debugging was not authorized.')) -join ' '
    try {
        [void](Wait-TskAuthorizedAndroidDevice -AdbExe $fakeAdb -TimeoutSeconds 0)
        throw 'An unauthorized device was accepted.'
    } catch {
        if ($_.Exception.Message -ne $expectedUnauthorizedError) {
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
            $content -notmatch 'Wait-TskAuthorizedAndroidDevice' -or
            $content -notmatch 'Set-TskAndroidWorkingDirectory') {
            throw "$entryScript does not use the shared Android setup helpers."
        }
    }
    $builder = Get-Content -Raw -Encoding UTF8 (Join-Path $repositoryRoot 'Build-TskSkinSwap-AndroidApk.ps1')
    if ($builder -match 'Join-Path \(\[IO\.Path\]::GetTempPath\(\)\)' -or
        $builder -notmatch 'New-TskAsciiTemporaryDirectory') {
        throw 'The Android APK builder does not use an ASCII-safe staging directory.'
    }
    $releaseBuilder = Get-Content -Raw -Encoding UTF8 (Join-Path $repositoryRoot 'Build-Android-Release.ps1')
    if ($releaseBuilder -notmatch 'Android-Messages\.zh-CN\.json') {
        throw 'The Android release package does not include the Chinese message file.'
    }

    Write-Host 'Android device authorization tests passed.'
} finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
