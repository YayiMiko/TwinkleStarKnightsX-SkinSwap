[CmdletBinding()]
param(
    [string]$Version = '0.2.9'
)

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') {
    throw 'Version must be a semantic version such as 0.1.0.'
}

$toolRoot = $PSScriptRoot
$androidRoot = Join-Path $toolRoot 'android'
$toolsRoot = Join-Path $toolRoot '.tools\release'
$artifactsRoot = Join-Path $toolRoot 'artifacts'
$packageName = "TskSkinSwap-Android-v$Version"
$stagingRoot = Join-Path $toolsRoot $packageName
$zipPath = Join-Path $artifactsRoot "$packageName.zip"
$hashPath = "$zipPath.sha256"
$packageVersion = (Get-Content -Raw -Encoding UTF8 (Join-Path $androidRoot 'package.json') | ConvertFrom-Json).version
$releaseBaseVersion = $Version -replace '-.*$', ''
if ($packageVersion -ne $releaseBaseVersion) {
    throw "Android package version $packageVersion does not match release version $Version."
}

Push-Location $androidRoot
try {
    & npm.cmd ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    & npm.cmd run build
    if ($LASTEXITCODE -ne 0) { throw 'Android runtime build failed.' }
} finally {
    Pop-Location
}

$resolvedToolsRoot = [IO.Path]::GetFullPath($toolsRoot)
$resolvedStagingRoot = [IO.Path]::GetFullPath($stagingRoot)
if (-not $resolvedStagingRoot.StartsWith($resolvedToolsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to prepare a staging directory outside the release tools root.'
}
if (Test-Path $resolvedStagingRoot) {
    Remove-Item -LiteralPath $resolvedStagingRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot 'android\runtime') | Out-Null
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null

Copy-Item (Join-Path $toolRoot 'README.android.md') (Join-Path $stagingRoot 'README.md')
Copy-Item (Join-Path $toolRoot 'CHANGELOG.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'THIRD_PARTY.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Android-Tools.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Apply-TskSkinSwap-Android.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Apply-TskSkinSwap-Android.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Build-TskSkinSwap-AndroidApk.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap-Android.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap-Android.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'catalog_downloader.py') $stagingRoot
Copy-Item (Join-Path $androidRoot 'installer.py') (Join-Path $stagingRoot 'android')
Copy-Item (Join-Path $androidRoot 'apk_patcher.py') (Join-Path $stagingRoot 'android')
Copy-Item (Join-Path $androidRoot 'apk_source.py') (Join-Path $stagingRoot 'android')
Copy-Item (Join-Path $androidRoot 'supported_apks.json') (Join-Path $stagingRoot 'android')
Copy-Item (Join-Path $androidRoot 'dist\tskskinswap.js') (Join-Path $stagingRoot 'android\runtime')
Set-Content -LiteralPath (Join-Path $stagingRoot 'VERSION') -Value $Version -Encoding ASCII

Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $hashPath -Value "$hash  $packageName.zip" -Encoding ASCII

Write-Host "Created $zipPath"
Write-Host "SHA256 $hash"
