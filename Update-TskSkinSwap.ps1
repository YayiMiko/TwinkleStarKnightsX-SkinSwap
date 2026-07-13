[CmdletBinding()]
param(
    [string]$GamePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [ValidateSet('HighQuality', 'LowQuality')]
    [string]$Quality = 'HighQuality',
    [ValidateSet('adult', 'general')]
    [string]$Edition = 'adult',
    [switch]$DryRun,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($SkipBuild -and -not $DryRun) {
    throw '-SkipBuild is only supported together with -DryRun.'
}
$toolRoot = $PSScriptRoot
$toolsRoot = Join-Path $toolRoot '.tools'
$outputRoot = Join-Path $toolRoot 'generated'
$stagingRoot = Join-Path $outputRoot 'staging'
$stagedMapping = Join-Path $stagingRoot 'mappings.json'
$downloadRoot = Join-Path $toolRoot 'downloaded\bundles'
$cacheRoot = Join-Path $env:USERPROFILE 'AppData\LocalLow\Unity\FANZAGAMES_twinkle_starknightsX'
$catalogPath = Join-Path $env:USERPROFILE 'AppData\LocalLow\FANZAGAMES\twinkle_starknightsX\com.unity.addressables\catalog_0.0.0.json'
$pluginDirectory = Join-Path $GamePath 'BepInEx\plugins\TskSkinSwap'
$pluginConfigRoot = Join-Path $GamePath 'BepInEx\config\TskSkinSwap'
$installStatePath = Join-Path $toolRoot '.install-state.json'
$gameAssemblyPath = Join-Path $GamePath 'GameAssembly.dll'
$globalMetadataPath = Join-Path $GamePath 'twinkle_starknightsX_Data\il2cpp_data\Metadata\global-metadata.dat'
$bepInExCore = Join-Path $GamePath 'BepInEx\core\BepInEx.Unity.IL2CPP.dll'
$bepInExZip = Join-Path $toolsRoot 'BepInEx-Unity.IL2CPP-win-x64-6.0.0-pre.2.zip'
$bepInExUrl = 'https://github.com/BepInEx/BepInEx/releases/download/v6.0.0-pre.2/BepInEx-Unity.IL2CPP-win-x64-6.0.0-pre.2.zip'
$bepInExSha256 = '616ec7eb06cf11b2a0000e8fcef04d1b12bb58e84a2e0bdac9523234fc193ceb'
$localDotnet = Join-Path $toolsRoot 'dotnet\dotnet.exe'
$dotnetVersion = '6.0.428'
$dotnetZip = Join-Path $toolsRoot "dotnet-sdk-$dotnetVersion-win-x64.zip"
$dotnetUrl = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$dotnetVersion/dotnet-sdk-$dotnetVersion-win-x64.zip"
$dotnetSha512 = 'c027cb47b264a13e529f8c7f3ba33ac91152b56749c8681fede1d6cd48723ae1e5f04a43bac1302ee81e35a5383f3e169654e5bb7c1d331dc11cce5a95052e32'
$packagedPlugin = Join-Path $toolRoot 'TskSkinSwap.dll'
$pythonDirectory = Join-Path $toolsRoot 'python'
$localPython = Join-Path $pythonDirectory 'python.exe'
$pythonZip = Join-Path $toolsRoot 'python-3.12.10-embed-amd64.zip'
$pythonUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
$pythonSha256 = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'

function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [ValidateSet('SHA256', 'SHA512')][string]$Algorithm = 'SHA256'
    )

    if (Test-Path $Destination) {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm $Algorithm).Hash
        if ($actual -eq $ExpectedHash) {
            return
        }
        Remove-Item -LiteralPath $Destination -Force
    }

    $temporary = "$Destination.download"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Write-Host "Downloading $Uri"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary
        $actual = (Get-FileHash -LiteralPath $temporary -Algorithm $Algorithm).Hash
        if ($actual -ne $ExpectedHash) {
            throw "$Algorithm mismatch for $Uri"
        }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Stop-StartedGameProcesses {
    param([datetime]$StartedAfter)

    Get-Process twinkle_starknightsX -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -ge $StartedAfter } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-OtherBepInExAddons {
    $excludedRoot = [IO.Path]::GetFullPath($pluginDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $files = @()
    foreach ($relativeRoot in @('BepInEx\plugins', 'BepInEx\patchers')) {
        $root = Join-Path $GamePath $relativeRoot
        if (Test-Path $root) {
            $files += Get-ChildItem $root -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { -not [IO.Path]::GetFullPath($_.FullName).StartsWith($excludedRoot, [StringComparison]::OrdinalIgnoreCase) }
        }
    }
    return @($files)
}

function Read-InstallState {
    if (-not (Test-Path $installStatePath)) {
        return $null
    }
    try {
        $state = Get-Content $installStatePath -Raw | ConvertFrom-Json
        if ($state.schemaVersion -ne 1 -or $null -eq $state.bepInExInstalledByTskSkinSwap) {
            return $null
        }
        return $state
    } catch {
        return $null
    }
}

function Write-InstallState {
    param(
        [bool]$BepInExInstalledByTskSkinSwap,
        [string]$OwnershipSource
    )

    $temporary = "$installStatePath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [ordered]@{
            schemaVersion = 1
            bepInExInstalledByTskSkinSwap = $BepInExInstalledByTskSkinSwap
            ownershipSource = $OwnershipSource
            recordedAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $installStatePath -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Test-LegacyTskBepInExInstall {
    $loaderFiles = @('.doorstop_version', 'doorstop_config.ini', 'winhttp.dll')
    $hasLoader = -not ($loaderFiles | Where-Object { -not (Test-Path (Join-Path $GamePath $_)) })
    $hasInstallerArchive = (Test-Path $bepInExZip) -and
        ((Get-FileHash -LiteralPath $bepInExZip -Algorithm SHA256).Hash -eq $bepInExSha256)
    return $hasLoader -and $hasInstallerArchive -and (Test-Path $bepInExCore) -and
        (@(Get-OtherBepInExAddons).Count -eq 0)
}

function Invoke-LocalPython {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $localPython @Arguments
        $script:LocalPythonExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Initialize-InteropAssemblies {
    param([string]$InteropPath)

    Write-Host 'Generating IL2CPP interop assemblies...'
    $startedAt = Get-Date
    $logPath = Join-Path $GamePath 'BepInEx\LogOutput.log'
    $previousLogWrite = if (Test-Path $logPath) { (Get-Item $logPath).LastWriteTimeUtc } else { [datetime]::MinValue }
    $process = Start-Process -FilePath (Join-Path $GamePath 'twinkle_starknightsX.exe') `
        -WorkingDirectory $GamePath -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(180)
    $startupComplete = $false
    do {
        Start-Sleep -Seconds 1
        if ((Test-Path $logPath) -and ((Get-Item $logPath).LastWriteTimeUtc -gt $previousLogWrite)) {
            try {
                $startupComplete = (Get-Content $logPath -Raw) -match 'Chainloader startup complete'
            } catch {
                $startupComplete = $false
            }
        }
    } while (-not $startupComplete -and -not $process.HasExited -and (Get-Date) -lt $deadline)

    Stop-StartedGameProcesses -StartedAfter $startedAt
    if (-not (Test-Path $InteropPath)) {
        throw 'BepInEx did not generate IL2CPP interop assemblies.'
    }
    if (-not $startupComplete) {
        throw "BepInEx did not finish validating the IL2CPP interop assemblies. Check $logPath"
    }
}

function Initialize-LocalPython {
    New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
    $legacyUnityPy = Test-Path (Join-Path $pythonDirectory 'Lib\site-packages\UnityPy')
    if (-not (Test-Path $localPython) -or $legacyUnityPy) {
        Get-RemoteFile -Uri $pythonUrl -Destination $pythonZip -ExpectedHash $pythonSha256
        if (Test-Path $pythonDirectory) {
            Remove-Item -LiteralPath $pythonDirectory -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $pythonDirectory | Out-Null
        Expand-Archive -LiteralPath $pythonZip -DestinationPath $pythonDirectory -Force
    }

    Invoke-LocalPython -Arguments @('-c', 'import hashlib, json, pathlib, urllib.request')
    if ($script:LocalPythonExitCode -ne 0) {
        throw 'The embedded Python standard library is unavailable.'
    }
}

function Initialize-LocalDotnet {
    $dotnetDirectory = Split-Path $localDotnet -Parent
    $installedVersion = $null
    if (Test-Path $localDotnet) {
        $installedVersion = (& $localDotnet --version).Trim()
    }
    if ($installedVersion -eq $dotnetVersion) {
        return
    }

    Get-RemoteFile -Uri $dotnetUrl -Destination $dotnetZip -ExpectedHash $dotnetSha512 -Algorithm SHA512
    if (Test-Path $dotnetDirectory) {
        Remove-Item -LiteralPath $dotnetDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $dotnetDirectory | Out-Null
    Expand-Archive -LiteralPath $dotnetZip -DestinationPath $dotnetDirectory -Force
    if (-not (Test-Path $localDotnet) -or (& $localDotnet --version).Trim() -ne $dotnetVersion) {
        throw "The pinned .NET SDK $dotnetVersion installation failed."
    }
}

function Test-PluginAssembly {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "The precompiled plugin DLL is missing: $Path"
    }
    try {
        $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($Path)
    } catch {
        throw "The precompiled plugin DLL is invalid: $Path"
    }
    if ($assemblyName.Name -ne 'TskSkinSwap') {
        throw "The precompiled plugin has an unexpected assembly name: $($assemblyName.Name)"
    }
}

function Resolve-PluginPath {
    if (Test-Path -LiteralPath $packagedPlugin) {
        Test-PluginAssembly -Path $packagedPlugin
        Write-Host "Using precompiled plugin: $packagedPlugin"
        return (Resolve-Path -LiteralPath $packagedPlugin).Path
    }

    if (-not (Test-Path (Join-Path $toolRoot '.git'))) {
        throw 'The release package is incomplete because TskSkinSwap.dll is missing. Extract the complete ZIP again.'
    }

    Write-Host 'Precompiled plugin not found in the source checkout; building the development plugin...'
    Initialize-LocalDotnet
    & (Join-Path $toolRoot 'Build-TskSkinSwap.ps1') -GamePath $GamePath -SkipInstall
    $developmentPlugin = Join-Path $toolRoot 'src\bin\Release\net6.0\TskSkinSwap.dll'
    Test-PluginAssembly -Path $developmentPlugin
    return (Resolve-Path -LiteralPath $developmentPlugin).Path
}

function Test-StagedMapping {
    param(
        [string]$Path,
        [string]$ExpectedGameHash,
        [string]$ExpectedMetadataHash
    )

    if (-not (Test-Path $Path)) {
        throw "Staged mapping was not generated: $Path"
    }
    $mapping = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (($mapping.schemaVersion -ne 2) -or
        ($mapping.gameAssemblySha256 -ne $ExpectedGameHash) -or
        ($mapping.globalMetadataSha256 -ne $ExpectedMetadataHash) -or
        (-not $mapping.characters) -or
        ($mapping.characters.Count -eq 0)) {
        throw 'Staged mapping failed schema or game fingerprint validation.'
    }
    foreach ($character in $mapping.characters) {
        if (-not $character.enabled) {
            continue
        }
        if (-not (Test-Path -LiteralPath $character.transformBundle)) {
            throw "Staged mapping references a missing bundle for character $($character.characterId)."
        }
        if ($character.transformBundleSize -and (Get-Item -LiteralPath $character.transformBundle).Length -ne $character.transformBundleSize) {
            throw "Staged mapping references a size-mismatched bundle for character $($character.characterId)."
        }
    }
    return $mapping
}

function Install-StagedFiles {
    param(
        [string]$MappingPath,
        [string]$PluginPath
    )

    $mappingTarget = Join-Path $pluginConfigRoot 'mappings.json'
    $pluginTarget = Join-Path $pluginDirectory 'TskSkinSwap.dll'
    New-Item -ItemType Directory -Force -Path $pluginConfigRoot, $pluginDirectory | Out-Null

    $suffix = [Guid]::NewGuid().ToString('N')
    $mappingNew = "$mappingTarget.$suffix.new"
    $pluginNew = "$pluginTarget.$suffix.new"
    $mappingBackup = "$mappingTarget.$suffix.backup"
    $pluginBackup = "$pluginTarget.$suffix.backup"
    $hadMapping = Test-Path $mappingTarget
    $hadPlugin = Test-Path $pluginTarget

    Copy-Item -LiteralPath $MappingPath -Destination $mappingNew
    Copy-Item -LiteralPath $PluginPath -Destination $pluginNew
    if ($hadMapping) {
        Copy-Item -LiteralPath $mappingTarget -Destination $mappingBackup
    }
    if ($hadPlugin) {
        Copy-Item -LiteralPath $pluginTarget -Destination $pluginBackup
    }

    $pluginPromoted = $false
    $mappingPromoted = $false
    try {
        # Installing the plugin first is fail-safe: a new plugin rejects an old mapping schema.
        Move-Item -LiteralPath $pluginNew -Destination $pluginTarget -Force
        $pluginPromoted = $true
        Move-Item -LiteralPath $mappingNew -Destination $mappingTarget -Force
        $mappingPromoted = $true
    } catch {
        if ($pluginPromoted) {
            if ($hadPlugin -and (Test-Path $pluginBackup)) {
                Copy-Item -LiteralPath $pluginBackup -Destination $pluginTarget -Force
            } elseif (-not $hadPlugin) {
                Remove-Item -LiteralPath $pluginTarget -Force -ErrorAction SilentlyContinue
            }
        }
        if ($mappingPromoted) {
            if ($hadMapping -and (Test-Path $mappingBackup)) {
                Copy-Item -LiteralPath $mappingBackup -Destination $mappingTarget -Force
            } elseif (-not $hadMapping) {
                Remove-Item -LiteralPath $mappingTarget -Force -ErrorAction SilentlyContinue
            }
        }
        throw
    } finally {
        Remove-Item -LiteralPath $mappingNew, $pluginNew, $mappingBackup, $pluginBackup -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ObsoleteBundles {
    param([object]$Mapping)

    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($character in $Mapping.characters) {
        if ($character.transformBundle) {
            [void]$expected.Add([IO.Path]::GetFullPath([string]$character.transformBundle))
        }
    }

    try {
        Get-ChildItem $downloadRoot -Filter 'tf_*.bundle' -File -ErrorAction SilentlyContinue |
            Where-Object { -not $expected.Contains([IO.Path]::GetFullPath($_.FullName)) } |
            Remove-Item -Force
        Get-ChildItem $downloadRoot -Filter 'bc_*.bundle' -File -ErrorAction SilentlyContinue | Remove-Item -Force
        Get-ChildItem $downloadRoot -Filter '*.part' -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $atlasTarget = Join-Path $pluginConfigRoot 'atlases'
        if (Test-Path $atlasTarget) {
            Remove-Item -LiteralPath $atlasTarget -Recurse -Force
        }
        foreach ($obsoleteTool in @('get-pip.py', 'dotnet-install.ps1')) {
            Remove-Item -LiteralPath (Join-Path $toolsRoot $obsoleteTool) -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path (Join-Path $toolRoot '.git'))) {
            foreach ($obsoletePath in @(
                (Join-Path $toolsRoot 'dotnet'),
                (Join-Path $toolRoot 'Build-TskSkinSwap.ps1'),
                (Join-Path $toolRoot 'src')
            )) {
                Remove-Item -LiteralPath $obsoletePath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Get-ChildItem $toolsRoot -Filter 'dotnet-sdk-*.zip' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $outputRoot) {
            Remove-Item -LiteralPath $outputRoot -Recurse -Force
        }
    } catch {
        Write-Warning "The update succeeded, but obsolete files could not be removed: $($_.Exception.Message)"
    }
}

if (-not (Test-Path $gameAssemblyPath) -or -not (Test-Path $globalMetadataPath)) {
    throw "GameAssembly.dll or global-metadata.dat was not found under $GamePath"
}

if (Get-Process twinkle_starknightsX -ErrorAction SilentlyContinue) {
    throw 'The game is running. Close it before applying TskSkinSwap.'
}

if (-not (Test-Path (Join-Path $toolRoot '.git'))) {
    Test-PluginAssembly -Path $packagedPlugin
}

New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null

$bepInExWasPresent = Test-Path $bepInExCore
$installState = Read-InstallState
if (-not $bepInExWasPresent) {
    Get-RemoteFile -Uri $bepInExUrl -Destination $bepInExZip -ExpectedHash $bepInExSha256
    Write-Host 'Installing BepInEx IL2CPP...'
    Expand-Archive -LiteralPath $bepInExZip -DestinationPath $GamePath -Force
    if (-not (Test-Path $bepInExCore)) {
        throw 'BepInEx installation did not produce the expected IL2CPP runtime.'
    }
    Write-InstallState -BepInExInstalledByTskSkinSwap $true -OwnershipSource 'installed'
} elseif (-not $installState) {
    $legacyOwned = Test-LegacyTskBepInExInstall
    $source = if ($legacyOwned) { 'legacy-inferred' } else { 'preexisting' }
    Write-InstallState -BepInExInstalledByTskSkinSwap $legacyOwned -OwnershipSource $source
}

$interopAssembly = Join-Path $GamePath 'BepInEx\interop\spine-unity.dll'
$currentGameHash = (Get-FileHash $gameAssemblyPath -Algorithm SHA256).Hash
$currentMetadataHash = (Get-FileHash $globalMetadataPath -Algorithm SHA256).Hash
$installedMapping = Join-Path $pluginConfigRoot 'mappings.json'
$previousGameHash = $null
$previousMetadataHash = $null
if (Test-Path $installedMapping) {
    try {
        $previousMapping = Get-Content $installedMapping -Raw -Encoding UTF8 | ConvertFrom-Json
        $previousGameHash = $previousMapping.gameAssemblySha256
        $previousMetadataHash = $previousMapping.globalMetadataSha256
    } catch {
        $previousGameHash = $null
        $previousMetadataHash = $null
    }
}
$gameChanged = (-not $previousGameHash) -or (-not $previousMetadataHash) `
    -or ($previousGameHash -ne $currentGameHash) -or ($previousMetadataHash -ne $currentMetadataHash)
if (-not (Test-Path $interopAssembly) -or $gameChanged) {
    Initialize-InteropAssemblies -InteropPath $interopAssembly
}

Initialize-LocalPython

if (-not (Test-Path $catalogPath)) {
    throw "The current Addressables catalog was not found: $catalogPath. Start the game once after updating, then close it and retry."
}

if (Test-Path $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

Write-Host 'Resolving and downloading high-quality transformation bundles...'
$downloaderArgs = @(
    (Join-Path $toolRoot 'catalog_downloader.py'),
    '--catalog', $catalogPath,
    '--output-dir', $downloadRoot,
    '--quality', $Quality,
    '--edition', $Edition,
    '--transforms-only',
    '--mapping-output', $stagedMapping,
    '--game-dir', $GamePath
)
if ($DryRun) {
    $downloaderArgs += '--dry-run'
}
Invoke-LocalPython -Arguments $downloaderArgs
if ($script:LocalPythonExitCode -ne 0) {
    throw "Bundle download failed with exit code $script:LocalPythonExitCode"
}
if ($DryRun) {
    return
}

$stagedDocument = Test-StagedMapping `
    -Path $stagedMapping `
    -ExpectedGameHash $currentGameHash `
    -ExpectedMetadataHash $currentMetadataHash

if (-not $SkipBuild) {
    $stagedPlugin = Resolve-PluginPath
    Install-StagedFiles -MappingPath $stagedMapping -PluginPath $stagedPlugin
}

Remove-ObsoleteBundles -Mapping $stagedDocument
Write-Host "Installed mapping: $(Join-Path $pluginConfigRoot 'mappings.json')"
