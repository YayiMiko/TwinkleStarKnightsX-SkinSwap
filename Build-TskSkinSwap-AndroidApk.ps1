[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputApk,
    [string]$OutputApk,
    [string]$RuntimeScript,
    [string]$ExpectedVersionName,
    [string]$Adb,
    [switch]$SkipRuntimeBuild,
    [switch]$ForcePortableTools,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$toolRoot = $PSScriptRoot
$commonTools = Join-Path $toolRoot 'Android-Tools.ps1'
if (-not (Test-Path $commonTools)) {
    throw 'Android-Tools.ps1 is missing. Extract the entire release ZIP and retry.'
}
. $commonTools
$androidRoot = Join-Path $toolRoot 'android'
$developmentToolsRoot = Join-Path $toolRoot '.tools\android'
$portableToolsRoot = Join-Path $toolRoot '.tools\android-apk'
$outputRoot = Join-Path $toolRoot '.tools\android-output'
$patcher = Join-Path $androidRoot 'apk_patcher.py'
$supportedApkManifest = Join-Path $androidRoot 'supported_apks.json'
$buildToolsUrl = 'https://dl.google.com/android/repository/build-tools_r36_windows.zip'
$buildToolsHash = 'aa1095cb14d83e483818a748a2c06faaeb8e601561b06a356a119a1b2ca280d3'
$jreUrl = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jre_x64_windows_hotspot_17.0.19_10.zip'
$jreHash = '79a598e1fbb4e16582d92c4ee22280a3c4d72fd52606e1e46b1223c0fe53b0da'
$objectionKeyUrl = 'https://raw.githubusercontent.com/sensepost/objection/2da035afe8620a6c81d1908c984c35ddedd11271/objection/utils/assets/objection.jks'
$objectionKeyHash = 'e8fef3f6339adbf309d23ec2cdf6c3a3c1393ebeb8a5bf17864c4fd540348155'
$pythonCandidates = @(
    (Join-Path $toolRoot '.tools\android-installer\python\python.exe'),
    (Join-Path $toolRoot '.tools\python\python.exe')
)
$python = $pythonCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $python) {
    $systemPython = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($systemPython) { $python = $systemPython.Source }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$FailureMessage = 'Command failed.'
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage Exit code: $LASTEXITCODE"
    }
}

function Get-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    if (Test-Path $Destination) {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -eq $Sha256) { return }
        Remove-Item -LiteralPath $Destination -Force
    }
    $temporary = "$Destination.part"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Write-Host "Downloading $Uri"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary
    $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw "Downloaded file failed SHA-256 validation: $Uri"
    }
    Move-Item -LiteralPath $temporary -Destination $Destination
}

function Initialize-ApkTools {
    $developmentKey = Join-Path $toolRoot '.tools\objection-src\objection\utils\assets\objection.jks'
    $developmentRequired = @(
        (Join-Path $developmentToolsRoot 'build-tools\aapt.exe'),
        (Join-Path $developmentToolsRoot 'build-tools\zipalign.exe'),
        (Join-Path $developmentToolsRoot 'build-tools\lib\apksigner.jar'),
        (Join-Path $developmentToolsRoot 'jdk\bin\java.exe'),
        $developmentKey
    )
    if (-not $ForcePortableTools -and
        ($developmentRequired | Where-Object { -not (Test-Path $_) }).Count -eq 0) {
        return [pscustomobject]@{
            Aapt = $developmentRequired[0]
            Zipalign = $developmentRequired[1]
            Apksigner = $developmentRequired[2]
            Java = $developmentRequired[3]
            Key = $developmentRequired[4]
        }
    }

    $downloads = Join-Path $portableToolsRoot 'downloads'
    $buildToolsZip = Join-Path $downloads 'build-tools_r36_windows.zip'
    $jreZip = Join-Path $downloads 'OpenJDK17U-jre_x64_windows_hotspot_17.0.19_10.zip'
    $key = Join-Path $portableToolsRoot 'objection.jks'
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    Get-VerifiedFile -Uri $buildToolsUrl -Destination $buildToolsZip -Sha256 $buildToolsHash
    Get-VerifiedFile -Uri $jreUrl -Destination $jreZip -Sha256 $jreHash
    Get-VerifiedFile -Uri $objectionKeyUrl -Destination $key -Sha256 $objectionKeyHash

    $buildTools = Join-Path $portableToolsRoot 'android-16'
    $jre = Join-Path $portableToolsRoot 'jdk-17.0.19+10-jre'
    if (-not (Test-Path (Join-Path $buildTools 'aapt.exe'))) {
        if (Test-Path $buildTools) { Remove-Item -LiteralPath $buildTools -Recurse -Force }
        Expand-Archive -LiteralPath $buildToolsZip -DestinationPath $portableToolsRoot -Force
    }
    if (-not (Test-Path (Join-Path $jre 'bin\java.exe'))) {
        if (Test-Path $jre) { Remove-Item -LiteralPath $jre -Recurse -Force }
        Expand-Archive -LiteralPath $jreZip -DestinationPath $portableToolsRoot -Force
    }
    return [pscustomobject]@{
        Aapt = Join-Path $buildTools 'aapt.exe'
        Zipalign = Join-Path $buildTools 'zipalign.exe'
        Apksigner = Join-Path $buildTools 'lib\apksigner.jar'
        Java = Join-Path $jre 'bin\java.exe'
        Key = $key
    }
}

function Get-ApkIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $badging = & $aapt dump badging $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect APK metadata: $Path"
    }
    $firstLine = $badging | Select-Object -First 1
    if ($firstLine -notmatch "package: name='(?<package>[^']+)' versionCode='(?<code>[^']+)' versionName='(?<name>[^']+)'") {
        throw "Unable to parse APK identity: $Path"
    }
    return [pscustomobject]@{
        Package = $Matches.package
        VersionCode = $Matches.code
        VersionName = $Matches.name
    }
}

function Get-ApkSigner {
    param([Parameter(Mandatory = $true)][string]$Path)

    $verification = & $java -jar $apksigner verify --verbose --print-certs $Path
    if ($LASTEXITCODE -ne 0) {
        throw "APK signature verification failed: $Path"
    }
    $digestLine = $verification | Where-Object { $_ -like 'Signer #1 certificate SHA-256 digest:*' }
    if (-not $digestLine) {
        throw "APK signer digest is missing: $Path"
    }
    return ($digestLine -split ':', 2)[1].Trim().ToLowerInvariant()
}

$apkTools = Initialize-ApkTools
$aapt = $apkTools.Aapt
$zipalign = $apkTools.Zipalign
$apksigner = $apkTools.Apksigner
$java = $apkTools.Java
$objectionKey = $apkTools.Key
$requiredTools = @($patcher, $supportedApkManifest, $aapt, $zipalign, $apksigner, $java, $objectionKey)
if (-not $python) {
    throw 'Python was not found.'
}
foreach ($path in $requiredTools) {
    if (-not (Test-Path $path)) {
        throw "Required Android patching tool is missing: $path"
    }
}

$resolvedInput = (Resolve-Path $InputApk).Path

if (-not $RuntimeScript) {
    $releaseRuntime = Join-Path $androidRoot 'runtime\tskskinswap.js'
    $developmentRuntime = Join-Path $androidRoot 'dist\tskskinswap.js'
    $RuntimeScript = if (Test-Path $releaseRuntime) { $releaseRuntime } else { $developmentRuntime }
}
if (-not $SkipRuntimeBuild -and -not (Test-Path (Join-Path $androidRoot 'runtime\tskskinswap.js'))) {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        throw 'npm.cmd was not found; pass -SkipRuntimeBuild with an existing runtime script.'
    }
    Push-Location $androidRoot
    try {
        Invoke-Checked -FilePath $npm.Source -Arguments @('run', 'build') -FailureMessage 'Android runtime build failed.'
    } finally {
        Pop-Location
    }
    $RuntimeScript = Join-Path $androidRoot 'dist\tskskinswap.js'
}
$resolvedRuntime = (Resolve-Path $RuntimeScript).Path

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$resolvedOutputRoot = [IO.Path]::GetFullPath($outputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$staging = New-TskAsciiTemporaryDirectory -Prefix 'TskSkinSwap-AndroidApk'
$stagedInput = Join-Path $staging 'input.apk'
$stagedKey = Join-Path $staging 'objection.jks'
$unsigned = Join-Path $staging 'unsigned.apk'
$aligned = Join-Path $staging 'aligned.apk'
$signed = Join-Path $staging 'signed.apk'
try {
    Copy-Item -LiteralPath $resolvedInput -Destination $stagedInput
    Copy-Item -LiteralPath $objectionKey -Destination $stagedKey
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $supportedApkManifest | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2) {
        throw 'Unsupported supported_apks.json schema.'
    }
    if ($manifest.sourceRepository -ne 'anosu/DMM-Mod') {
        throw 'Unsupported APK source repository.'
    }
    $expectedPackage = [string]$manifest.package
    $expectedSigner = [string]$manifest.signerSha256
    $expectedTranslationModule = [string]$manifest.translationModule
    $expectedGadget = [string]$manifest.gadgetSha256
    $inputIdentity = Get-ApkIdentity -Path $stagedInput
    if ($inputIdentity.Package -ne $expectedPackage) {
        throw "Unsupported APK package: $($inputIdentity.Package)"
    }
    if ($inputIdentity.VersionCode -notmatch '^\d+$' -or
        $inputIdentity.VersionName -notmatch '^\d+(?:\.\d+)*$') {
        throw "Unsupported APK version: $($inputIdentity.VersionName) ($($inputIdentity.VersionCode))"
    }
    if ($ExpectedVersionName -and $inputIdentity.VersionName -ne $ExpectedVersionName) {
        throw "APK version $($inputIdentity.VersionName) does not match expected version $ExpectedVersionName."
    }
    $inputSigner = Get-ApkSigner -Path $stagedInput
    if ($inputSigner -ne $expectedSigner) {
        throw "Unsupported APK signer: $inputSigner"
    }
    if (-not $OutputApk) {
        $OutputApk = Join-Path $outputRoot "TskSkinSwap-Android-$($inputIdentity.VersionName)-patched.apk"
    }
    $resolvedOutput = [IO.Path]::GetFullPath($OutputApk)
    if (-not $resolvedOutput.StartsWith($resolvedOutputRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output APK must be under $outputRoot"
    }

    Invoke-Checked -FilePath $python -Arguments @(
        $patcher,
        '--input-apk', $stagedInput,
        '--runtime', $resolvedRuntime,
        '--output-apk', $unsigned,
        '--expected-translation-module', $expectedTranslationModule,
        '--expected-gadget-sha256', $expectedGadget
    ) -FailureMessage 'APK script embedding failed.'

    Invoke-Checked -FilePath $zipalign -Arguments @('-p', '-f', '4', $unsigned, $aligned) `
        -FailureMessage 'APK alignment failed.'

    Invoke-Checked -FilePath $java -Arguments @(
        '-jar', $apksigner, 'sign',
        '--ks', $stagedKey,
        '--ks-pass', 'pass:basil-joule-bug',
        '--ks-key-alias', 'objection',
        '--v1-signing-enabled', 'false',
        '--v2-signing-enabled', 'false',
        '--v3-signing-enabled', 'true',
        '--v4-signing-enabled', 'false',
        '--out', $signed,
        $aligned
    ) -FailureMessage 'APK signing failed.'

    Invoke-Checked -FilePath $zipalign -Arguments @('-c', '-p', '4', $signed) `
        -FailureMessage 'Signed APK alignment verification failed.'

    $outputIdentity = Get-ApkIdentity -Path $signed
    if ($outputIdentity.Package -ne $inputIdentity.Package -or
        $outputIdentity.VersionCode -ne $inputIdentity.VersionCode -or
        $outputIdentity.VersionName -ne $inputIdentity.VersionName) {
        throw 'Patched APK identity differs from the input APK.'
    }
    $outputSigner = Get-ApkSigner -Path $signed
    if ($outputSigner -ne $inputSigner) {
        throw 'Patched APK signer differs from the input APK.'
    }

    Remove-Item -LiteralPath $resolvedOutput -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $signed -Destination $resolvedOutput
    $hash = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Created patched APK: $resolvedOutput"
    Write-Host "Package: $($outputIdentity.Package)"
    Write-Host "Version: $($outputIdentity.VersionName) ($($outputIdentity.VersionCode))"
    Write-Host "SHA256: $hash"

    if ($Install) {
        if (-not $Adb) {
            $adbCandidates = @(
                (Join-Path $toolRoot '.tools\android-installer\platform-tools\adb.exe'),
                (Join-Path $developmentToolsRoot 'platform-tools\adb.exe')
            )
            $Adb = $adbCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $Adb) {
                $systemAdb = Get-Command adb.exe -ErrorAction SilentlyContinue
                if ($systemAdb) { $Adb = $systemAdb.Source }
            }
        }
        if (-not $Adb -or -not (Test-Path $Adb)) {
            throw 'ADB is missing.'
        }
        $devices = @(& $Adb devices | Select-String -Pattern "\tdevice$")
        if ($devices.Count -ne 1) {
            throw "Exactly one authorized Android device is required; found $($devices.Count)."
        }
        & $Adb shell am force-stop $expectedPackage | Out-Null
        Invoke-Checked -FilePath $Adb -Arguments @('install', '-r', $signed) `
            -FailureMessage 'ADB refused the patched APK. The original app was not uninstalled.'
        Write-Host 'Patched APK installed without clearing application data.'
    }
} finally {
    if (Test-Path $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
