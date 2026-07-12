[CmdletBinding()]
param(
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Version must be a semantic version such as 1.0.0.'
}

$toolRoot = $PSScriptRoot
$releaseRoot = Join-Path $toolRoot '.tools\release\pc'
$stagingRoot = Join-Path $releaseRoot 'TskSkinSwap'
$artifactsRoot = Join-Path $toolRoot 'artifacts'
$zipPath = Join-Path $artifactsRoot "TskSkinSwap-PC-v$Version.zip"
$hashPath = "$zipPath.sha256"

if (Test-Path $releaseRoot) {
    Remove-Item -LiteralPath $releaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot 'src') | Out-Null
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null

Copy-Item (Join-Path $toolRoot 'README.pc.md') (Join-Path $stagingRoot 'README.md')
Copy-Item (Join-Path $toolRoot 'README.en.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'THIRD_PARTY.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Apply-TskSkinSwap.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Build-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Update-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'catalog_downloader.py') $stagingRoot
Copy-Item (Join-Path $toolRoot 'scanner.py') $stagingRoot
Copy-Item (Join-Path $toolRoot 'src\Plugin.cs') (Join-Path $stagingRoot 'src')
Copy-Item (Join-Path $toolRoot 'src\TskSkinSwap.csproj') (Join-Path $stagingRoot 'src')

Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $hashPath -Value "$hash  TskSkinSwap-PC-v$Version.zip" -Encoding ASCII

Write-Host "Created $zipPath"
Write-Host "SHA256 $hash"
