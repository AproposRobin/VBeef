<#
.SYNOPSIS
  Runs .github/workflows/windows.yml's steps on this machine, in a scratch folder (docs/CI.md > Proving it locally).

.DESCRIPTION
  1. git clone --depth 1 of -Source (default: this checkout) into <Scratch>\repo  (only committed files are used);
  2. scripts\ci-windows.ps1 with fresh downloads of Beef, llvm-mingw and SDL2 into <Scratch>\tools (sha256 checked):
     fetch, host, build, test, package;
  3. with -Compare, a normal scripts\package.ps1 build of -Source (its own Beef install and committed vbhost.dll)
     and a comparison of the two zips' entry lists.
  Nothing is installed and no registry is touched: Beef is unpacked with 7-Zip.
  The suites find Beef at C:\Program Files\BeefLang (hard-coded), so on this machine that installed copy is the one
  the compile / debug / catalog suites use; the workflow unpacks the pinned Beef into that folder instead.
.PARAMETER Scratch
  An empty or missing folder to work in.
.PARAMETER Steps
  Which ci-windows.ps1 steps to run (default: all of fetch, host, build, test, package).
#>
param(
    [Parameter(Mandatory)][string]$Scratch,
    [string]$Source = "",
    [string[]]$Steps = @('fetch', 'host', 'build', 'test', 'package'),
    [switch]$Compare,
    [switch]$AllowStaleHost
)
$ErrorActionPreference = 'Stop'
if (-not $Source) { $Source = Split-Path -Parent $PSScriptRoot }
if ((Test-Path $Scratch) -and (Get-ChildItem $Scratch -Force | Select-Object -First 1)) { throw "Scratch folder '$Scratch' is not empty" }
New-Item -ItemType Directory -Force $Scratch | Out-Null
$repo = Join-Path $Scratch 'repo'
$srcUrl = 'file:///' + (Resolve-Path $Source).Path.Replace([string][char]92, '/')
git clone --depth 1 -q $srcUrl $repo
if ($LASTEXITCODE) { throw 'clone failed' }
Write-Host ("== cloned {0}" -f (git -C $repo rev-parse --short HEAD))
$tools = Join-Path $Scratch 'tools'
$work = Join-Path $Scratch 'work'
$extra = @(); if ($AllowStaleHost) { $extra += '-AllowStaleHost' }
$dist = Join-Path $Scratch 'dist'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\ci-windows.ps1') -Step ($Steps -join ",") -Tools $tools -Work $work -Dist $dist @extra
if ($LASTEXITCODE) { throw "ci-windows.ps1 failed ($LASTEXITCODE)" }

if ($Compare) {
    $normalZip = Join-Path $Scratch 'normal-zip'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Source 'scripts\package.ps1') -Out (Join-Path $Scratch 'normal-out') -ZipDir $normalZip
    if ($LASTEXITCODE) { throw 'normal package.ps1 failed' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Entries($z) { $a = [IO.Compression.ZipFile]::OpenRead($z); try { @($a.Entries | ForEach-Object { "$($_.FullName)`t$($_.Length)" }) } finally { $a.Dispose() } }
    $ci = Get-ChildItem $dist -Filter 'VisualBeef-*-win64.zip' | Where-Object { $_.Name -notlike '*-alpha-*' } | Select-Object -First 1
    $nz = Get-ChildItem $normalZip -Filter '*.zip' | Select-Object -First 1
    $a = Entries $ci.FullName; $b = Entries $nz.FullName
    $names = { param($l) $l | ForEach-Object { $_.Split("`t")[0] } }
    $diffNames = Compare-Object (& $names $a) (& $names $b)
    Write-Host ("zip entries: ci={0} normal={1} name differences={2}" -f $a.Count, $b.Count, @($diffNames).Count)
    $diffNames | ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
    $sizeDiff = Compare-Object $a $b | Where-Object { $true }
    Write-Host ("entries differing in name or size: {0}" -f @($sizeDiff).Count)
    $sizeDiff | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
}
Write-Host "== local CI emulation finished: $Scratch"
