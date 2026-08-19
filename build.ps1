param(
    [string]$Framework = (Join-Path (Split-Path -Parent $PSScriptRoot) "routerui")
)

$ErrorActionPreference = "Stop"
$builder = Join-Path $Framework "tools/build-plugin.ps1"
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
    throw "MWEF build tool not found: $builder"
}
$output = Join-Path $PSScriptRoot "dist"
$outputRelativeToFramework = [System.IO.Path]::GetRelativePath(
    [System.IO.Path]::GetFullPath($Framework),
    [System.IO.Path]::GetFullPath($output)
)

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("nekocoffee-build-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    foreach ($name in @("mwef-plugin.json", "LICENSE", "README.md", "i18n", "overlay")) {
        $source = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $staging -Recurse
        }
    }
    & $builder -Source $staging -OutputDirectory $outputRelativeToFramework
} finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
