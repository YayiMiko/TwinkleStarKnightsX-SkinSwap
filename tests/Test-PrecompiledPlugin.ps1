$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "TskSkinSwap-plugin-$([Guid]::NewGuid().ToString('N'))"

try {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repositoryRoot 'Update-TskSkinSwap.ps1'),
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count) {
        throw 'Update-TskSkinSwap.ps1 did not parse.'
    }
    foreach ($name in @('Test-PluginAssembly', 'Resolve-PluginPath')) {
        $function = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Invoke-Expression $function.Extent.Text
    }

    $toolRoot = Join-Path $testRoot 'release'
    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
    $packagedPlugin = Join-Path $toolRoot 'TskSkinSwap.dll'
    Add-Type -TypeDefinition 'public sealed class TestPluginMarker {}' -OutputAssembly $packagedPlugin

    Test-PluginAssembly -Path $packagedPlugin
    $resolved = Resolve-PluginPath
    if ($resolved -ne $packagedPlugin) {
        throw 'The precompiled plugin path was not selected.'
    }

    Set-Content -LiteralPath $packagedPlugin -Value 'invalid' -Encoding ASCII
    try {
        Test-PluginAssembly -Path $packagedPlugin
        throw 'An invalid plugin DLL was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'plugin DLL is invalid') {
            throw
        }
    }

    Remove-Item -LiteralPath $packagedPlugin -Force
    try {
        Resolve-PluginPath
        throw 'A release without a plugin DLL was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'release package is incomplete') {
            throw
        }
    }

    Write-Host 'Precompiled plugin tests passed.'
} finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
