$script:TskPlatformToolsVersion = '37.0.0'
$script:TskPlatformToolsHash = '4fe305812db074cea32903a489d061eb4454cbc90a49e8fea677f4b7af764918'
$script:TskPythonVersion = '3.12.10'
$script:TskPythonHash = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'

function Get-TskVerifiedRemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
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

function Get-TskAndroidAdb {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)

    $toolsRoot = Join-Path $ToolRoot '.tools\android-installer'
    $platformToolsRoot = Join-Path $toolsRoot 'platform-tools'
    $downloadedAdb = Join-Path $platformToolsRoot 'adb.exe'
    $developmentAdb = Join-Path $ToolRoot '.tools\android\platform-tools\adb.exe'
    if (Test-Path $downloadedAdb) {
        $sourceProperties = Join-Path $platformToolsRoot 'source.properties'
        if ((Test-Path $sourceProperties) -and
            ((Get-Content -Raw -LiteralPath $sourceProperties) -match
                "Pkg.Revision\s*=\s*$([regex]::Escape($script:TskPlatformToolsVersion))")) {
            return $downloadedAdb
        }
        Remove-Item -LiteralPath $platformToolsRoot -Recurse -Force
    }
    if (Test-Path $developmentAdb) { return $developmentAdb }

    $systemAdb = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($systemAdb) { return $systemAdb.Source }

    $platformToolsZip = Join-Path $toolsRoot "platform-tools-$script:TskPlatformToolsVersion-windows.zip"
    Get-TskVerifiedRemoteFile `
        -Uri "https://dl.google.com/android/repository/platform-tools_r$script:TskPlatformToolsVersion-win.zip" `
        -Destination $platformToolsZip `
        -ExpectedHash $script:TskPlatformToolsHash
    if (Test-Path $platformToolsRoot) {
        Remove-Item -LiteralPath $platformToolsRoot -Recurse -Force
    }
    Expand-Archive -LiteralPath $platformToolsZip -DestinationPath $toolsRoot -Force
    $sourceProperties = Join-Path $platformToolsRoot 'source.properties'
    if (-not (Test-Path $downloadedAdb) -or
        -not (Test-Path $sourceProperties) -or
        -not ((Get-Content -Raw -LiteralPath $sourceProperties) -match
            "Pkg.Revision\s*=\s*$([regex]::Escape($script:TskPlatformToolsVersion))")) {
        throw 'Android Platform Tools extraction failed version validation.'
    }
    return $downloadedAdb
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

function Get-TskCompatibleSourceApk {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$PythonExe
    )

    $apkCache = Join-Path $ToolRoot '.tools\android-installer\apk'
    $apkSource = Join-Path $ToolRoot 'android\apk_source.py'
    $manifestPath = Join-Path $ToolRoot 'android\supported_apks.json'
    if (-not (Test-Path $apkSource) -or -not (Test-Path $manifestPath)) {
        throw 'Android APK downloader files are missing. Extract the entire release ZIP and retry.'
    }

    New-Item -ItemType Directory -Force -Path $apkCache | Out-Null
    & $PythonExe $apkSource --output-dir $apkCache | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Compatible APK download failed.' }

    $metadataPath = Join-Path $apkCache 'source-apk.json'
    if (-not (Test-Path $metadataPath)) {
        throw 'Compatible APK downloader did not create metadata.'
    }
    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
    if ($metadata.schemaVersion -ne 1 -or
        $metadata.assetName -notmatch '^Kurusuta-X\.Mod_[0-9.]+_patched\.apk$' -or
        $metadata.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        [string]$metadata.versionCode -notmatch '^\d+$') {
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

    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $matches = @($manifest.apks | Where-Object {
        $_.sha256 -eq $sourceHash -and
        [string]$_.versionCode -eq [string]$metadata.versionCode -and
        $_.assetName -eq $metadata.assetName
    })
    if ($manifest.schemaVersion -ne 1 -or $matches.Count -ne 1) {
        throw 'The downloaded compatible APK is not in the supported allowlist.'
    }

    return [pscustomobject]@{
        Path = $sourceApk
        Metadata = $metadata
        SupportedApk = $matches[0]
    }
}
