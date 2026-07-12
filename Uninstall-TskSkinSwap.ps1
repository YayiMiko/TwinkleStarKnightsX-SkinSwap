[CmdletBinding()]
param(
    [string]$GamePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [switch]$KeepGeneratedMappings
)

$ErrorActionPreference = 'Stop'
$pluginDirectory = Join-Path $GamePath 'BepInEx\plugins\TskSkinSwap'
$configDirectory = Join-Path $GamePath 'BepInEx\config\TskSkinSwap'

if (Test-Path $pluginDirectory) {
    Remove-Item -LiteralPath $pluginDirectory -Recurse -Force
}
if (Test-Path $configDirectory) {
    Remove-Item -LiteralPath $configDirectory -Recurse -Force
}
if (-not $KeepGeneratedMappings) {
    $generatedDirectory = Join-Path $PSScriptRoot 'generated'
    if (Test-Path $generatedDirectory) {
        Remove-Item -LiteralPath $generatedDirectory -Recurse -Force
    }
}

Write-Host 'TskSkinSwap plugin and runtime configuration were removed.'
Write-Host 'BepInEx and all original game/cache files were left untouched.'
