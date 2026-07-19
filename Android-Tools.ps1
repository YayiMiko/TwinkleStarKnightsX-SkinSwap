$script:TskPlatformToolsVersion = '37.0.1'
$script:TskPlatformToolsHash = '84df1e5628bc7e6a9f2bf750ab98c591a99a6d622fd48f789cf278336bab5b99'
$script:TskPythonVersion = '3.12.10'
$script:TskPythonHash = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'

function Get-TskVerifiedRemoteFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (Test-Path $Destination) {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -eq $ExpectedHash) { return }
        Remove-Item -LiteralPath $Destination -Force
    }

    $temporary = "$Destination.part"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    $failures = @()
    foreach ($candidate in $Uri) {
        Write-Host "Downloading $candidate"
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $candidate -OutFile $temporary
            $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $ExpectedHash) {
                throw "Downloaded file failed SHA-256 validation: $candidate"
            }
            Move-Item -LiteralPath $temporary -Destination $Destination
            return
        } catch {
            $failures += "${candidate}: $($_.Exception.Message)"
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    throw "All verified download sources failed:`n$($failures -join "`n")"
}

function Get-TskAndroidAdb {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)

    $toolsRoot = Join-Path $ToolRoot '.tools\android-installer'
    $legacyAdbCandidates = @(
        (Join-Path $toolsRoot 'platform-tools\adb.exe'),
        (Join-Path $ToolRoot '.tools\android\platform-tools\adb.exe')
    )
    foreach ($legacyAdb in $legacyAdbCandidates) {
        if (Test-Path $legacyAdb) {
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'SilentlyContinue'
                & $legacyAdb kill-server 2>$null | Out-Null
            } finally {
                $ErrorActionPreference = $previousPreference
            }
        }
    }

    $systemAdb = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($systemAdb) { return $systemAdb.Source }

    $runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) 'TskSkinSwap\android-platform-tools'
    $platformToolsRoot = Join-Path $runtimeRoot 'platform-tools'
    $runtimeAdb = Join-Path $platformToolsRoot 'adb.exe'
    $sourceProperties = Join-Path $platformToolsRoot 'source.properties'
    if ((Test-Path $runtimeAdb) -and
        (Test-Path $sourceProperties) -and
        ((Get-Content -Raw -LiteralPath $sourceProperties) -match
            "Pkg.Revision\s*=\s*$([regex]::Escape($script:TskPlatformToolsVersion))")) {
        return $runtimeAdb
    }
    if (Test-Path $runtimeAdb) {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            & $runtimeAdb kill-server 2>$null | Out-Null
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $runtimeRoot) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }

    $platformToolsZip = Join-Path $toolsRoot "platform-tools-$script:TskPlatformToolsVersion-windows.zip"
    Get-TskVerifiedRemoteFile `
        -Uri @(
            "https://dl-ssl.google.com/android/repository/platform-tools_r$script:TskPlatformToolsVersion-win.zip",
            "https://redirector.gvt1.com/edgedl/android/repository/platform-tools_r$script:TskPlatformToolsVersion-win.zip",
            "https://dl.google.com/android/repository/platform-tools_r$script:TskPlatformToolsVersion-win.zip"
        ) `
        -Destination $platformToolsZip `
        -ExpectedHash $script:TskPlatformToolsHash
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    Expand-Archive -LiteralPath $platformToolsZip -DestinationPath $runtimeRoot -Force
    if (-not (Test-Path $runtimeAdb) -or
        -not (Test-Path $sourceProperties) -or
        -not ((Get-Content -Raw -LiteralPath $sourceProperties) -match
            "Pkg.Revision\s*=\s*$([regex]::Escape($script:TskPlatformToolsVersion))")) {
        throw 'Android Platform Tools extraction failed version validation.'
    }
    return $runtimeAdb
}

function Get-TskAndroidPython {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)

    $toolsRoot = Join-Path $ToolRoot '.tools\android-installer'
    $pythonRoot = Join-Path $toolsRoot 'python'
    $pythonExe = Join-Path $pythonRoot 'python.exe'
    if (Test-Path $pythonExe) { return $pythonExe }

    $pythonZip = Join-Path $toolsRoot "python-$script:TskPythonVersion-embed-amd64.zip"
    Get-TskVerifiedRemoteFile `
        -Uri "https://www.python.org/ftp/python/$script:TskPythonVersion/python-$script:TskPythonVersion-embed-amd64.zip" `
        -Destination $pythonZip `
        -ExpectedHash $script:TskPythonHash
    if (Test-Path $pythonRoot) {
        Remove-Item -LiteralPath $pythonRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $pythonRoot | Out-Null
    Expand-Archive -LiteralPath $pythonZip -DestinationPath $pythonRoot -Force
    if (-not (Test-Path $pythonExe)) {
        throw 'Portable Python extraction failed.'
    }
    return $pythonExe
}

function Start-TskAdbServer {
    param([Parameter(Mandatory = $true)][string]$AdbExe)

    # Windows PowerShell 5 promotes native stderr to an error record. ADB writes
    # its normal first-start daemon messages there, so check the exit code instead.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $AdbExe start-server 2>$null | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "ADB server failed to start with exit code $exitCode."
    }
}

function ConvertFrom-TskAdbDevicesOutput {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Output)

    foreach ($line in $Output) {
        if ($line -match '^(?<Serial>\S+)\s+(?<State>device|unauthorized|offline|recovery|sideload|bootloader|host)(?:\s|$)') {
            [pscustomobject]@{
                Serial = $Matches.Serial
                State = $Matches.State
            }
        } elseif ($line -match '^(?<Serial>\S+)\s+no permissions(?:\s|$)') {
            [pscustomobject]@{
                Serial = $Matches.Serial
                State = 'no permissions'
            }
        }
    }
}

function Get-TskAdbDevices {
    param([Parameter(Mandatory = $true)][string]$AdbExe)

    # ADB may write normal daemon startup messages to stderr. Windows
    # PowerShell must not promote those messages to terminating errors.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& $AdbExe devices 2>$null)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "ADB could not list connected devices (exit code $exitCode)."
    }
    return @(ConvertFrom-TskAdbDevicesOutput -Output $output)
}

function Wait-TskAuthorizedAndroidDevice {
    param(
        [Parameter(Mandatory = $true)][string]$AdbExe,
        [ValidateRange(0, 600)][int]$TimeoutSeconds = 90,
        [ValidateRange(100, 10000)][int]$PollMilliseconds = 1000
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = $null
    do {
        $devices = @(Get-TskAdbDevices -AdbExe $AdbExe)
        if ($devices.Count -gt 1) {
            throw 'More than one Android device is connected. Disconnect the extra device and run this BAT again.'
        }
        if ($devices.Count -eq 1 -and $devices[0].State -eq 'device') {
            if ($lastState) {
                Write-Host 'USB debugging authorization confirmed.'
            }
            return $devices[0].Serial
        }

        $state = if ($devices.Count -eq 0) { 'missing' } else { $devices[0].State }
        if ($state -ne $lastState) {
            switch ($state) {
                'unauthorized' {
                    Write-Host 'Phone detected, waiting for USB debugging approval...'
                    Write-Host 'Unlock the phone. In the "Allow USB debugging?" prompt, tap Allow.'
                    Write-Host 'You may also select "Always allow from this computer".'
                }
                'offline' {
                    Write-Host 'The phone is offline. Unlock it, reconnect the USB cable, and keep this window open.'
                }
                'no permissions' {
                    Write-Host 'Windows cannot access the phone. Reconnect it and check the phone USB settings.'
                }
                'missing' {
                    Write-Host 'Waiting for an Android phone. Connect it with a data-capable USB cable and unlock it.'
                }
                default {
                    Write-Host "The phone is in ADB state '$state'. Start Android normally and reconnect it."
                }
            }
            $lastState = $state
        }

        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ($true)

    switch ($lastState) {
        'unauthorized' {
            throw 'The phone is connected but USB debugging was not authorized. Unlock the phone, accept the USB debugging prompt, and run this BAT again. If no prompt appears, turn USB debugging off and on, then reconnect the cable.'
        }
        'offline' {
            throw 'The phone stayed offline. Reconnect the USB cable, unlock the phone, and run this BAT again.'
        }
        'no permissions' {
            throw 'Windows could not access the phone. Reconnect it, select a USB data mode, and run this BAT again.'
        }
        default {
            throw 'No Android phone was detected. Use a data-capable USB cable, unlock the phone, enable USB debugging, and run this BAT again.'
        }
    }
}

function New-TskAsciiTemporaryDirectory {
    param(
        [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Prefix = 'TskSkinSwap',
        [string[]]$CandidateRoot
    )

    if (-not $CandidateRoot) {
        $CandidateRoot = @(
            [IO.Path]::GetTempPath(),
            (Join-Path ([Environment]::GetFolderPath(
                [Environment+SpecialFolder]::CommonApplicationData)) 'TskSkinSwap\temp'),
            (Join-Path ([Environment]::GetFolderPath(
                [Environment+SpecialFolder]::CommonDocuments)) 'TskSkinSwap\temp')
        )
    }

    foreach ($root in $CandidateRoot) {
        if (-not $root) { continue }
        $resolvedRoot = [IO.Path]::GetFullPath($root)
        if ($resolvedRoot -match '[^\x00-\x7F]') { continue }

        $directory = Join-Path $resolvedRoot "$Prefix-$([Guid]::NewGuid().ToString('N'))"
        try {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
            return $directory
        } catch {
            continue
        }
    }

    throw 'Unable to create the ASCII-only temporary directory required by the Android build tools.'
}

function Get-TskCompatibleSourceApk {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [string]$MinimumVersionName,
        [string]$RequiredVersionName
    )

    $apkCache = Join-Path $ToolRoot '.tools\android-installer\apk'
    $apkSource = Join-Path $ToolRoot 'android\apk_source.py'
    $manifestPath = Join-Path $ToolRoot 'android\supported_apks.json'
    if (-not (Test-Path $apkSource) -or -not (Test-Path $manifestPath)) {
        throw 'Android APK downloader files are missing. Extract the entire release ZIP and retry.'
    }
    if ($MinimumVersionName -and $RequiredVersionName) {
        throw 'MinimumVersionName and RequiredVersionName cannot be combined.'
    }

    New-Item -ItemType Directory -Force -Path $apkCache | Out-Null
    $arguments = @($apkSource, '--output-dir', $apkCache)
    if ($MinimumVersionName) {
        $arguments += @('--minimum-version-name', $MinimumVersionName)
    }
    if ($RequiredVersionName) {
        $arguments += @('--required-version-name', $RequiredVersionName)
    }
    & $PythonExe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Compatible APK download failed.' }

    $metadataPath = Join-Path $apkCache 'source-apk.json'
    if (-not (Test-Path $metadataPath)) {
        throw 'Compatible APK downloader did not create metadata.'
    }
    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
    if ($metadata.schemaVersion -ne 2 -or
        $metadata.sourceRepository -ne 'anosu/DMM-Mod' -or
        $metadata.assetName -notmatch '^Kurusuta-X\.Mod_[0-9.]+_patched\.apk$' -or
        $metadata.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        [string]$metadata.versionName -notmatch '^\d+(?:\.\d+)*$') {
        throw 'Compatible APK downloader returned invalid metadata.'
    }

    $sourceApk = Join-Path $apkCache $metadata.assetName
    if (-not (Test-Path $sourceApk)) {
        throw 'Compatible APK downloader did not return a valid file.'
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourceApk -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $metadata.sha256.ToLowerInvariant()) {
        throw 'The compatible APK failed SHA-256 validation.'
    }

    $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    if ($policy.schemaVersion -ne 2 -or
        $policy.sourceRepository -ne $metadata.sourceRepository) {
        throw 'The compatible APK source policy is invalid.'
    }

    return [pscustomobject]@{
        Path = $sourceApk
        Metadata = $metadata
        SourcePolicy = $policy
    }
}
