<#
.SYNOPSIS
    Builds the PATCHD release zip and its SHA-256 hashes.

.DESCRIPTION
    Creates dist\PATCHD-<version>.zip containing the four files users need, plus dist\SHA256SUMS.txt
    with hashes for the zip and every file inside it. Upload both to the GitHub release and paste
    SHA256SUMS.txt into the release notes.

    The version comes from $script:Version in PATCHD.ps1.
#>
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$files = 'PATCHD.ps1', 'PATCHD.ico', 'Install-PATCHD.ps1', 'Install.cmd'

$m = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'PATCHD.ps1') -Raw), "\`$script:Version\s*=\s*'([0-9.]+)'")
if (-not $m.Success) { throw 'Could not find $script:Version in PATCHD.ps1.' }
$version = $m.Groups[1].Value

$dist  = Join-Path $root 'dist'
$stage = Join-Path $dist "PATCHD-$version"
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $stage }

$zip = Join-Path $dist "PATCHD-$version.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

$lines = foreach ($p in @($zip) + @($files | ForEach-Object { Join-Path $stage $_ })) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path $p -Leaf)
}
$sums = Join-Path $dist 'SHA256SUMS.txt'
$lines | Set-Content -LiteralPath $sums -Encoding ASCII
Remove-Item -LiteralPath $stage -Recurse -Force

Write-Host "Built $zip"
Get-Content -LiteralPath $sums
