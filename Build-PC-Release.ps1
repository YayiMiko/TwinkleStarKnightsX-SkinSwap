[CmdletBinding()]
param(
    [string]$Version = '1.2.1'
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
$pluginSource = Join-Path $toolRoot 'src\Plugin.cs'
$pluginText = Get-Content -Raw -Encoding UTF8 -LiteralPath $pluginSource
if ($pluginText -notmatch "PluginVersion = `"$([regex]::Escape($Version))`"") {
    throw "PluginVersion does not match release version $Version."
}
$projectText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $toolRoot 'src\TskSkinSwap.csproj')
if ($projectText -notmatch "<Version>$([regex]::Escape($Version))</Version>") {
    throw "Project version does not match release version $Version."
}

if (Test-Path $releaseRoot) {
    Remove-Item -LiteralPath $releaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot 'src') | Out-Null
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null

Copy-Item (Join-Path $toolRoot 'README.pc.md') (Join-Path $stagingRoot 'README.md')
$stagedReadme = Join-Path $stagingRoot 'README.md'
$readmeText = Get-Content -Raw -Encoding UTF8 -LiteralPath $stagedReadme
$readmeText = $readmeText.Replace('Release 1.2.0', "Release $Version").Replace('v1.2.0', "v$Version")
Set-Content -LiteralPath $stagedReadme -Value $readmeText -Encoding UTF8
Copy-Item (Join-Path $toolRoot 'README.en.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'THIRD_PARTY.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Apply-TskSkinSwap.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Build-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Update-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'catalog_downloader.py') $stagingRoot
Copy-Item $pluginSource (Join-Path $stagingRoot 'src')
Copy-Item (Join-Path $toolRoot 'src\TskSkinSwap.csproj') (Join-Path $stagingRoot 'src')

Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $hashPath -Value "$hash  TskSkinSwap-PC-v$Version.zip" -Encoding ASCII

Write-Host "Created $zipPath"
Write-Host "SHA256 $hash"
