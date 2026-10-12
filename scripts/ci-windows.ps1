<#
.SYNOPSIS
  The Windows build, test and package steps of .github/workflows/windows.yml (docs/CI.md).
  scripts/ci-github-local.ps1 runs the same steps in a scratch folder, so the workflow and the local proof cannot drift.

.DESCRIPTION
  Steps (give one or more with -Step, they run in order):
    fetch      download Beef, llvm-mingw and SDL2 (sha256 checked against the pins below) and unpack them under -Tools.
               A tool whose marker file is already there is not downloaded again (the workflow caches -Tools by pin).
               -AllowUnpinned (the beef-canary workflow only): Beef is not the pinned build but the newest dated nightly
               in the archive index at nightly.beeflang.org; its file name, date, sha256 and commit go to the job summary.
               llvm-mingw and SDL2 stay pinned. Without the switch the pinned Beef is the only one accepted.
    host       rebuild Native\bin\win64\vbhost.dll + vbhost.lib from source with Native\build_windows.ps1, then compare
               the export list of the committed DLL with the rebuilt one and fail when they differ.
    build      BeefBuild: VisualBeefTests (Debug), VisualBeefCore and VisualBeefTests (Release).
    test       run every suite that needs no outside source corpus (docs/Testing.md), one at a time; fail on any failure.
    package    scripts\package.ps1 for the full package and for -Minimal; zips + .sha256 land in -Dist.

  The Beef install is unpacked with 7-Zip (no installer runs). BeefHome is where Beef ends up (default -Tools\beef).
  The suites look for Beef at C:\Program Files\BeefLang, so the workflow passes that folder as -BeefHome.
#>
param(
    [Parameter(Mandatory)][string[]]$Step,
    [string]$Tools = (Join-Path $env:RUNNER_TEMP 'vbtools'),
    [string]$Work = (Join-Path $env:RUNNER_TEMP 'vbwork'),
    [string]$Dist = '',
    [string]$BeefHome = '',
    [switch]$AllowStaleHost,
    [switch]$AllowUnpinned
)
$ErrorActionPreference = 'Stop'
$Step = @($Step | ForEach-Object { $_ -split "," } | Where-Object { $_ })
foreach ($s in $Step) { if ($s -notin @("fetch", "host", "build", "test", "package")) { throw "unknown step $s" } }
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Dist) { $Dist = Join-Path $Repo 'dist' }
if (-not $BeefHome) { $BeefHome = Join-Path $Tools 'beef' }

# ---- pins -----------------------------------------------------------------------------------------------------------
# Beef 0.43.6 is a nightly build (there is no 0.43.6 release on GitHub): the 2026-09-14 build, commit 19ee8d2e.
$Pins = @(
    @{ Name = 'beef';  File = 'BeefSetup_0_43_6__09_14_2026.exe'; Url = 'https://nightly.beeflang.org/BeefSetup_0_43_6__09_14_2026.exe'
       Sha = '65ee0f1cda0a89637d69eb660a4459efd6e3281d417d1dc41a12edad4bb21880' },
    @{ Name = 'mingw'; File = 'llvm-mingw-20261006-ucrt-x86_64.zip'
       Url = 'https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/llvm-mingw-20261006-ucrt-x86_64.zip'
       Sha = '317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a' },
    @{ Name = 'sdl2';  File = 'SDL2-devel-2.32.10-mingw.zip'
       Url = 'https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-devel-2.32.10-mingw.zip'
       Sha = 'f15cff5fca62ec9381a016ef1d42a95c638cd72d2f226ba5781c76fe43dbd1ac' }
)
$MingwRoot = Join-Path $Tools 'llvm-mingw-20261006-ucrt-x86_64'
$Sdl2Root = Join-Path $Tools 'SDL2-2.32.10\x86_64-w64-mingw32'
$BeefBuildExe = Join-Path $BeefHome 'bin\BeefBuild.exe'
$env:VB_MINGW = $MingwRoot
$env:SDL2_MINGW = $Sdl2Root
$env:VB_BEEFBUILD = $BeefBuildExe
New-Item -ItemType Directory -Force $Work | Out-Null

function Get-SevenZip {
    $c = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) { if (Test-Path $p) { return $p } }
    throw '7-Zip (7z.exe) not found'
}
function Get-Exports([string]$dll) {
    $ro = Join-Path $MingwRoot 'bin\llvm-readobj.exe'
    $lines = & $ro --coff-exports $dll
    if ($LASTEXITCODE) { throw "llvm-readobj failed on $dll" }
    $names = @($lines | ForEach-Object { if ($_ -match '^\s+Name:\s+(\S+)\s*$') { $Matches[1] } } | Sort-Object)
    return , $names
}
function Write-Summary([string]$text) {
    Write-Host $text
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $text -Encoding utf8 }
}

# -AllowUnpinned only: the newest dated nightly listed in the archive index (one line per build, newest date wins).
function Resolve-NightlyBeef {
    $html = (Invoke-WebRequest -Uri 'https://nightly.beeflang.org/' -UseBasicParsing).Content
    $best = $null
    foreach ($line in ($html -split "`n")) {
        $m = [regex]::Match($line, '^<a href=(BeefSetup_(\d+)_(\d+)_(\d+)__(\d\d)_(\d\d)_(\d{4})\.exe)>')
        if (-not $m.Success) { continue }
        $c = [regex]::Match($line, 'github\.com/beefytech/Beef/commit/([0-9a-f]{40})')
        $date = [datetime]::new([int]$m.Groups[7].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value)
        if ($null -eq $best -or $date -gt $best.Date) {
            $best = [pscustomobject]@{
                File = $m.Groups[1].Value; Date = $date; Url = "https://nightly.beeflang.org/$($m.Groups[1].Value)"
                Commit = $(if ($c.Success) { $c.Groups[1].Value } else { '' })
            }
        }
    }
    if ($null -eq $best) { throw 'no BeefSetup nightly listed at https://nightly.beeflang.org/' }
    return $best
}
# -AllowUnpinned only: unpacks the newest nightly into -BeefHome. Only a folder this script unpacked before is replaced.
function Install-BeefUnpinned([string]$sz, [string]$dl) {
    $n = Resolve-NightlyBeef
    if (Test-Path (Join-Path $BeefHome 'bin')) {
        if (-not (Get-ChildItem -LiteralPath $BeefHome -Filter '.vb-beef-*' -Force -File -ErrorAction SilentlyContinue)) {
            throw "$BeefHome holds a Beef install this script did not unpack; refusing to replace it"
        }
        Remove-Item -Recurse -Force $BeefHome
    }
    $file = Join-Path $dl $n.File
    if (Test-Path $file) { Remove-Item -Force $file }
    Write-Host "== download $($n.Url) (unpinned: newest nightly in the archive index)"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $n.Url -OutFile $file -UseBasicParsing
    $sha = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    Write-Host "== unpack $($n.File) (unpinned, sha256 $sha)"
    New-Item -ItemType Directory -Force $BeefHome | Out-Null
    & $sz x -y -bso0 -bsp0 "-o$BeefHome" $file '-ir!bin' '-ir!BeefLibs' '-ir!LICENSE.TXT' '-ir!LICENSES.TXT' '-ir!readme.txt'
    if ($LASTEXITCODE) { throw "7z failed on $($n.File)" }
    Set-Content -Path (Join-Path $BeefHome ".vb-beef-unpinned-$($sha.Substring(0, 12)).ok") -Value $sha -Encoding ascii
    $commit = if ($n.Commit) { $n.Commit } else { '(not in the index)' }
    Write-Summary ("### Beef nightly (unpinned)`n`n| Item | Value |`n|---|---|`n| File | ``{0}`` |`n| Build date | {1} |`n| SHA-256 | ``{2}`` |`n| Beef commit (archive index) | ``{3}`` |`n" -f $n.File, $n.Date.ToString('yyyy-MM-dd'), $sha, $commit)
}

function Step-Fetch {
    $dl = Join-Path $Tools 'dl'
    New-Item -ItemType Directory -Force $dl | Out-Null
    $sz = Get-SevenZip
    foreach ($p in $Pins) {
        if ($p.Name -eq 'beef' -and $AllowUnpinned) { continue }   # Install-BeefUnpinned, below
        $dest = switch ($p.Name) { 'beef' { $BeefHome } 'mingw' { $Tools } 'sdl2' { $Tools } }
        $marker = Join-Path $dest ".vb-$($p.Name)-$($p.Sha.Substring(0, 12)).ok"
        if (Test-Path $marker) { Write-Host "== $($p.Name): already unpacked ($marker)"; continue }
        $file = Join-Path $dl $p.File
        if (-not (Test-Path $file)) {
            Write-Host "== download $($p.Url)"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $p.Url -OutFile $file -UseBasicParsing
        }
        $got = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
        if ($got -ne $p.Sha) { Remove-Item -Force $file; throw "sha256 of $($p.File) is $got, expected $($p.Sha)" }
        Write-Host "== unpack $($p.File) (sha256 ok)"
        New-Item -ItemType Directory -Force $dest | Out-Null
        if ($p.Name -eq 'beef') {
            # Only what BeefBuild, the debugger tests and the catalog need: bin\, BeefLibs\ and the licence files.
            & $sz x -y -bso0 -bsp0 "-o$dest" $file '-ir!bin' '-ir!BeefLibs' '-ir!LICENSE.TXT' '-ir!LICENSES.TXT' '-ir!readme.txt'
        } else {
            & $sz x -y -bso0 -bsp0 "-o$dest" $file
        }
        if ($LASTEXITCODE) { throw "7z failed on $($p.File)" }
        Set-Content -Path $marker -Value $p.Sha -Encoding ascii
    }
    if ($AllowUnpinned) { Install-BeefUnpinned $sz $dl }
    # The Beef installer writes bin\BeefConfig.toml (where BeefBuild finds corlib); unpacking skips the installer.
    Set-Content -Path (Join-Path $BeefHome 'bin\BeefConfig.toml') -Value "Version = 1`nUnversionedLibDirs = [`"../BeefLibs`"]" -Encoding ascii
    foreach ($f in @($BeefBuildExe, (Join-Path $MingwRoot 'bin\clang++.exe'), (Join-Path $Sdl2Root 'lib\libSDL2.a'))) {
        if (-not (Test-Path $f)) { throw "after fetch, missing: $f" }
    }
    $v = (Get-Item $BeefBuildExe).VersionInfo.FileVersion
    Write-Summary "Beef: BeefBuild $v ($BeefHome); llvm-mingw 20261006; SDL2 2.32.10"
    if ($AllowUnpinned) {
        $pv = (Get-Item $BeefBuildExe).VersionInfo.ProductVersion
        Write-Summary "BeefBuild FileVersion ``$v``, ProductVersion ``$pv``"
    } elseif ($v -notlike '0.43.6*') { throw "BeefBuild reports '$v', expected 0.43.6" }
}

function Step-Host {
    $dll = Join-Path $Repo 'Native\bin\win64\vbhost.dll'
    $committed = Join-Path $Work 'vbhost-committed.dll'
    Copy-Item $dll $committed -Force
    $before = Get-Exports $committed
    & (Join-Path $Repo 'Native\build_windows.ps1') -Clean
    $after = Get-Exports $dll
    $cs = (Get-FileHash -Algorithm SHA256 $committed).Hash.ToLowerInvariant()
    $ns = (Get-FileHash -Algorithm SHA256 $dll).Hash.ToLowerInvariant()
    Set-Content (Join-Path $Work 'exports-committed.txt') $before -Encoding ascii
    Set-Content (Join-Path $Work 'exports-rebuilt.txt') $after -Encoding ascii
    $diff = Compare-Object $before $after
    Write-Summary ("vbhost.dll rebuilt from source: {0} exports (committed DLL: {1}); sha256 committed {2}, rebuilt {3}" -f $after.Count, $before.Count, $cs.Substring(0, 16), $ns.Substring(0, 16))
    if ($diff) {
        $diff | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
        $msg = 'The committed vbhost.dll and the DLL rebuilt from source export different symbols: rebuild and commit Native/bin/win64.'
        if ($AllowStaleHost) { Write-Warning "$msg (-AllowStaleHost: continuing, local proof only)" } else { throw $msg }
    }
    if ($after.Count -lt 100) { throw "vbhost.dll exports only $($after.Count) symbols" }
}

function Invoke-BeefBuild([string]$project, [string]$config) {
    $log = Join-Path $Work "beefbuild-$project-$config.log"
    # The Release link occasionally dies with "LLVM ERROR: out of memory" on a busy machine: one retry.
    foreach ($attempt in 1, 2) {
        Write-Host "== BeefBuild $project ($config) attempt $attempt"
        $p = Start-Process -FilePath $BeefBuildExe -ArgumentList @("-workspace=`"$Repo`"", "-config=$config", '-platform=Win64', "-project=$project") `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        if ($p.ExitCode -eq 0) { return }
        Get-Content $log -Tail 40; Get-Content "$log.err" -Tail 20
    }
    throw "BeefBuild $project $config failed (exit $($p.ExitCode))"
}
function Step-Build {
    Invoke-BeefBuild 'VisualBeefTests' 'Debug'
    Invoke-BeefBuild 'VisualBeefCore' 'Release'
    Invoke-BeefBuild 'VisualBeefTests' 'Release'
}

function Step-Test {
    $exe = Join-Path $Repo 'build\Debug_Win64\VisualBeefTests\VisualBeefTests.exe'
    if (-not (Test-Path $exe)) { throw "missing $exe (run the build step)" }
    $scratch = Join-Path $Work 'suites'
    if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch }
    New-Item -ItemType Directory -Force $scratch | Out-Null
    $suites = @('edits', 'flow', 'calls', 'lifetime', 'textforms', 'classes', 'safety', 'parser', 'catalog', 'diagnostics',
        'hotkeys', 'update', 'host', 'vocabulary', 'stress', 'compile', 'debug')
    $rows = @(); $failed = 0; $firstFail = ''
    Remove-Item -Force (Join-Path $Work 'first-failure.txt') -ErrorAction SilentlyContinue
    foreach ($s in $suites) {
        $args2 = switch ($s) { 'compile' { "compile -out `"$scratch\compile`"" } 'debug' { "debug -out `"$scratch\debug`"" } default { $s } }
        $log = Join-Path $scratch "$s.log"
        $t0 = Get-Date
        cmd /c "`"$exe`" $args2 > `"$log`" 2>&1"
        $code = $LASTEXITCODE
        $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        $last = (Get-Content $log | Where-Object { $_ -match '(failures|passed|checks).*[0-9]' } | Select-Object -Last 1); if (-not $last) { $last = (Get-Content $log | Where-Object { $_.Trim() } | Select-Object -Last 1) }
        if ($code -ne 0) { $failed++; if (-not $firstFail) { $firstFail = "$s (exit $code)" }; Get-Content $log | Where-Object { $_ -match 'FAIL' } | Select-Object -First 20 | ForEach-Object { Write-Host $_ } }
        $rows += "| ``$s`` | $code | $secs | $last |"
        Write-Host ("{0,-10} exit={1} {2,6}s  {3}" -f $s, $code, $secs, $last)
    }
    # The Release build of the same suites: the scope-delete class of bug only shows up there.
    $rel = Join-Path $Repo 'build\Release_Win64\VisualBeefTests\VisualBeefTests.exe'
    if (Test-Path $rel) {
        foreach ($s in @('edits', 'classes', 'parser', 'safety', 'stress', 'update')) {
            $log = Join-Path $scratch "release-$s.log"
            cmd /c "`"$rel`" $s > `"$log`" 2>&1"
            $code = $LASTEXITCODE
            $last = (Get-Content $log | Where-Object { $_ -match '(failures|passed|checks).*[0-9]' } | Select-Object -Last 1); if (-not $last) { $last = (Get-Content $log | Where-Object { $_.Trim() } | Select-Object -Last 1) }
            if ($code -ne 0) { $failed++; if (-not $firstFail) { $firstFail = "$s (Release, exit $code)" } }
            $rows += "| ``$s`` (Release) | $code | | $last |"
            Write-Host ("release {0,-10} exit={1}  {2}" -f $s, $code, $last)
        }
    }
    Write-Summary (("### Suites`n`n| Suite | Exit | Seconds | Last line |`n|---|---|---|---|`n") + ($rows -join "`n"))
    Write-Summary ("Suites: $($rows.Count) run, $failed failed")
    if ($firstFail) { Set-Content -Path (Join-Path $Work 'first-failure.txt') -Value "suite $firstFail" -Encoding ascii }
    if ($failed) { throw "$failed suite(s) failed" }
}

# The zips carry only user pages (docs/ with front matter audience: user). A developer page fails the step.
function Test-PackageDocs {
    param([string]$ZipPath)
    $denied = @('Architecture.md', 'Testing.md', 'CI.md', 'Code-Signing.md', 'Codegen.md', 'Parsing-and-Layout.md', 'Catalog-and-Types.md', 'Linux.md', 'Host-Integration.md', 'Roadmap.md', 'Vocabulary.md', 'CHANGELOG.md', 'README.md')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in @($zip.Entries | Where-Object { $_.FullName -like 'docs/*.md' })) {
            $name = $e.FullName.Substring(5)
            if ($name -like '*Audit*' -or $denied -contains $name) { throw "$(Split-Path -Leaf $ZipPath) contains a developer page: $($e.FullName)" }
            $sr = New-Object System.IO.StreamReader($e.Open())
            try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $top = $text.Substring(0, [Math]::Min(300, $text.Length))
            if ($top -notmatch '(?m)^audience: user\r?$') { throw "$(Split-Path -Leaf $ZipPath): $($e.FullName) does not say audience: user" }
        }
    }
    finally { $zip.Dispose() }
}

function Step-Package {
    New-Item -ItemType Directory -Force $Dist | Out-Null
    & (Join-Path $PSScriptRoot 'package.ps1') -ZipDir $Dist -Out (Join-Path $Dist 'VisualBeef')
    & (Join-Path $PSScriptRoot 'package.ps1') -Minimal -NoBuild -ZipDir $Dist -Out (Join-Path $Dist 'VisualBeef-minimal')
    if (Test-Path (Join-Path $Dist 'VisualBeef-minimal\docs')) { throw 'the minimal package has a docs folder' }
    Report-Zips
}
function Report-Zips {
    $rows = @()
    Get-ChildItem $Dist -Filter *.zip | ForEach-Object {
        $h = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
        $want = (Get-Content "$($_.FullName).sha256" -TotalCount 1).Split(' ')[0]
        if ($h -ne $want) { throw "$($_.Name) does not match its .sha256 file" }
        Test-PackageDocs $_.FullName
        $rows += "| $($_.Name) | $([Math]::Round($_.Length / 1MB, 1)) MB | ``$h`` |"
    }
    if (-not $rows) { throw "no zip in $Dist" }
    Write-Summary (("### Packages`n`n| File | Size | SHA-256 |`n|---|---|---|`n") + ($rows -join "`n"))
}

foreach ($s in $Step) {
    Write-Host "##### step: $s"
    switch ($s) {
        'fetch' { Step-Fetch }
        'host' { Step-Host }
        'build' { Step-Build }
        'test' { Step-Test }
        'package' { Step-Package }
    }
}
