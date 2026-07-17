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
