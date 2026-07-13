[CmdletBinding()]
param(
    [string]$Version = '1.2.2',
    [string]$GamePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$VerifiedPluginPath
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

& (Join-Path $toolRoot 'Build-TskSkinSwap.ps1') -GamePath $GamePath -SkipInstall
$builtPlugin = Join-Path $toolRoot 'src\bin\Release\net6.0\TskSkinSwap.dll'
if (-not (Test-Path -LiteralPath $builtPlugin)) {
    throw 'The precompiled plugin DLL was not generated.'
}
$assemblyName = [Reflection.AssemblyName]::GetAssemblyName($builtPlugin)
if ($assemblyName.Name -ne 'TskSkinSwap' -or $assemblyName.Version.ToString() -ne "$Version.0") {
    throw "Precompiled plugin version $($assemblyName.Version) does not match release version $Version."
}
$pluginBinary = $builtPlugin
if ($VerifiedPluginPath) {
    $pluginBinary = (Resolve-Path -LiteralPath $VerifiedPluginPath).Path
    $verifiedAssemblyName = [Reflection.AssemblyName]::GetAssemblyName($pluginBinary)
    if ($verifiedAssemblyName.Name -ne 'TskSkinSwap' -or $verifiedAssemblyName.Version.ToString() -ne "$Version.0") {
        throw "Verified plugin version $($verifiedAssemblyName.Version) does not match release version $Version."
    }
    Write-Host "Packaging verified plugin: $pluginBinary"
}

if (Test-Path $releaseRoot) {
    Remove-Item -LiteralPath $releaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null

Copy-Item (Join-Path $toolRoot 'README.pc.md') (Join-Path $stagingRoot 'README.md')
$stagedReadme = Join-Path $stagingRoot 'README.md'
$readmeText = Get-Content -Raw -Encoding UTF8 -LiteralPath $stagedReadme
$readmeText = $readmeText -replace 'Release \d+\.\d+\.\d+', "Release $Version"
$readmeText = $readmeText -replace 'v\d+\.\d+\.\d+', "v$Version"
Set-Content -LiteralPath $stagedReadme -Value $readmeText -Encoding UTF8
Copy-Item (Join-Path $toolRoot 'README.en.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'THIRD_PARTY.md') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Apply-TskSkinSwap.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap.bat') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Uninstall-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'Update-TskSkinSwap.ps1') $stagingRoot
Copy-Item (Join-Path $toolRoot 'catalog_downloader.py') $stagingRoot
Copy-Item $pluginBinary (Join-Path $stagingRoot 'TskSkinSwap.dll')

Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $hashPath -Value "$hash  TskSkinSwap-PC-v$Version.zip" -Encoding ASCII

Write-Host "Created $zipPath"
Write-Host "SHA256 $hash"
