# Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
#
# The release smoke pass (docs/Releasing.md, docs/Testing.md#release-smoke). Owner rule, 2026-10-12: nothing is
# published without a verified stable build and a regression pass on the EXACT artifact that ships. This script
# runs that pass on a win64 package (the full zip) and writes a report that `scripts/release.mjs publish` demands.
#
#   powershell -File scripts\release-smoke.ps1 -Zip <path to VisualBeef-x.y.z-win64.zip> [-Out <report folder>]
#   powershell -File scripts\release-smoke.ps1 -Tag <vX.Y.Z[-alpha]>                    [-Out <report folder>]
#
# What it does (each step is a phase in the report):
#   verify   -Tag: downloads the full win64 zip + .sha256 + release.json of the tag from AproposRobin/VBeef with gh,
#            checks the hash and `gh attestation verify`. -Zip: hashes it (and checks a sibling .sha256).
#            Extracts it into a scratch install folder and checks the package layout and VERSION.txt.
#   version  the packaged VisualBeefEditor.exe --version: exit 0 and the VERSION.txt version.
#   matrix   the end-to-end self-test session (VB_SELFTEST=session) on the packaged exe, Dark + Darker, 1280x800 +
#            1920x1080, 100% + 125% (VB_UI_SCALE), captures (VB_SHOTS, PrintWindow) into <Out>\shots\<run>\.
#            Each run must end `[SELFTEST] done failures=0`, have no [ASSERT] line, no crash report, and every
#            requested capture must exist.
#   fresh    fresh settings (empty VB_HOME): a start with no project (nodoc, the start page and project switch, the
#            documentation panel on the package's own docs folder), then a start that opens a scratch
#            project, opens a function, the Node menu, Editor Preferences > Updates, Help > Check for Updates
#            (the answer is recorded: up to date or the next version, never "not set up"), then the session
#            (compile of the sample with BeefBuild).
#   update   the update end to end: a staged newer copy installs ("update complete", installed.json), then a
#            staged copy whose program exits at once rolls back ("previous copy restored").
#   soak     60 s of the editor's main window (responding, alive), then a clean exit (close message, exit code 0).
#
# Failure = any [ASSERT] line, any crash report under a data folder, a non-zero exit, a matrix run without
# `done failures=0`, a missing capture, the update end to end not reaching its end state.
# Output: <Out>\smoke-<first 12 hex of the zip's sha256>.json + .md. Exit 0 = passed, 1 = failed.
# Default <Out>: <repository>\build\smoke (where `release.mjs publish` looks).
#
# Needs a desktop session (the editor opens real windows) and BeefBuild (C:\Program Files\BeefLang\bin). Windows
# PowerShell 5.1 or newer. Heavy processes run one at a time at BelowNormal; only processes this script starts (and
# the editors the update helper starts inside its scratch folder) are stopped. Never touches installed editors.
#
# -Only <phases> runs a subset for development; the report is then marked complete=false and publish refuses it.
# -AllowOffline accepts "could not reach GitHub" as the Check for Updates answer (never use it for a release).

[CmdletBinding()]
param(
  [string]$Zip,
  [string]$Tag,
  [string]$Out,
  [string]$Repo = "AproposRobin/VBeef",
  [string]$Gh = "C:\Program Files\GitHub CLI\gh.exe",
  [string]$BeefBuild = "C:\Program Files\BeefLang\bin\BeefBuild.exe",
  [int]$SoakSeconds = 60,
  [string[]]$Only,
  [switch]$AllowOffline,
  [switch]$KeepWork
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
if (-not $Out) { $Out = Join-Path $RepoRoot "build\smoke" }
if (($Zip -and $Tag) -or (-not $Zip -and -not $Tag)) { throw "give exactly one of -Zip <path> or -Tag <vX.Y.Z>" }
$AllPhases = @("verify", "version", "matrix", "fresh", "update", "soak")
$Phases = if ($Only) { @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ }) } else { $AllPhases }
foreach ($ph in $Phases) { if ($AllPhases -notcontains $ph) { throw "unknown phase '$ph' (verify, version, matrix, fresh, update, soak)" } }
if ($Phases -notcontains "verify") { $Phases = @("verify") + $Phases } # the package must always be unpacked
$Complete = (@($AllPhases | Where-Object { $Phases -notcontains $_ }).Count -eq 0)

New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Work = Join-Path ([IO.Path]::GetTempPath()) ("vbsmoke-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $Work | Out-Null
$Started = Get-Date
$Started_pids = New-Object System.Collections.Generic.List[int]
$Report = [ordered]@{
  schema = 1; tool = "scripts/release-smoke.ps1"; passed = $false; complete = $Complete; phases = @()
  startedAt = $Started.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); finishedAt = ""; seconds = 0
  machine = "$env:COMPUTERNAME / $([Environment]::OSVersion.VersionString)"
  zip = [ordered]@{}; tag = $Tag; version = ""; failures = @(); warnings = @(); notes = @()
}
$Failures = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]

function Say([string]$m) { Write-Host ("[smoke " + (Get-Date).ToString("HH:mm:ss") + "] " + $m) }
function Fail([string]$phase, [string]$m) { $Failures.Add("${phase}: $m"); Say "FAIL $phase`: $m" }
function Warn([string]$phase, [string]$m) { $Warnings.Add("${phase}: $m"); Say "warn $phase`: $m" }

$VbVars = @("VB_HOME", "VB_NO_IDLE", "VB_SELFTEST", "VB_SHOTS", "VB_UI_SCALE", "VB_UPDATE_HEALTH_MS", "VB_DEBUG_CRASH_TEST", "VB_SELFTEST_DELETE_OK")
function Reset-VbEnv { foreach ($v in $VbVars) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue } }

# ---- window helpers (PrintWindow capture of the editor window; no global input) ----
Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Runtime.InteropServices; using System.Drawing; using System.Drawing.Imaging;
public static class SmokeWin {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public static void Park(IntPtr h) { RECT r; GetClientRect(h, out r); int x = (r.R - r.L) / 2, y = 12; PostMessage(h, 0x0200, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF))); }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static void Shot(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    int w = r.R - r.L, ht = r.B - r.T;
    using (var bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
      bmp.Save(path, ImageFormat.Png);
    }
  }
}
"@

# ---- process bookkeeping: only what this script starts, and editors started from inside its scratch folder ----
function Start-Ours([string]$exe, [string]$argLine, [string]$cwd) {
  if ($argLine) { $p = Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $cwd -PassThru }
  else { $p = Start-Process -FilePath $exe -WorkingDirectory $cwd -PassThru }
  $Started_pids.Add($p.Id)
  try { $p.PriorityClass = 'BelowNormal' } catch {}
  return $p
}
function Stop-Pid([int]$id) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} }
function Stop-OursUnder([string]$folder) {
  $found = @()
  foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) {
    $path = $null; try { $path = $pr.Path } catch {}
    if ($path -and $path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase)) { $found += $pr.Id; if (-not $Started_pids.Contains($pr.Id)) { $Started_pids.Add($pr.Id) }; Stop-Pid $pr.Id }
  }
  return $found
}

function Get-SessionLogs([string]$home2) {
  $d = Join-Path $home2 "logs"
  if (-not (Test-Path $d)) { return @() }
  return @(Get-ChildItem $d -Filter "visualbeef-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*crash*" } | Sort-Object LastWriteTime)
}
function Get-CrashFiles([string]$home2) {
  $d = Join-Path $home2 "logs"
  $r = @()
  if (Test-Path $d) { $r += @(Get-ChildItem $d -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*crash*" -or $_.Extension -eq ".dmp" }) }
  return $r
}

# ---- one self-test run of the packaged editor, with captures ----
function Invoke-EditorRun {
  param([string]$Name, [string]$Tests, [string]$Project, [string]$Home2, [string]$Exe, [string]$Scale = "", [string]$Size = "1280x800",
        [int]$TimeoutSec = 600, [string]$ShotDir, [string]$AfterDonePattern = "")
  $res = [ordered]@{ name = $Name; tests = $Tests; size = $Size; scale = $(if ($Scale) { $Scale } else { "1" }); result = "timeout"; failures = $null
                     asserts = 0; selftestFails = @(); shotsRequested = 0; shotsMissing = @(); crash = @(); seconds = 0; log = ""; ok = $false; why = @(); repeated = $false }
  New-Item -ItemType Directory -Force $Home2, $ShotDir | Out-Null
  Reset-VbEnv
  $env:VB_HOME = $Home2; $env:VB_NO_IDLE = "1"; $env:VB_SELFTEST = $Tests; $env:VB_SHOTS = $ShotDir
  if ($Scale) { $env:VB_UI_SCALE = $Scale }
  $t0 = Get-Date
  $argLine = if ($Project) { "`"$Project`"" } else { "" }
  $p = Start-Ours $Exe $argLine (Split-Path -Parent $Exe)
  Reset-VbEnv
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $hwnd = [IntPtr]::Zero
  $shotNames = New-Object System.Collections.Generic.List[string]
  $curSize = $Size
  function SizeTo([string]$wh) { $a = $wh.Split('x'); [SmokeWin]::ShowWindow($hwnd, 1) | Out-Null; [SmokeWin]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, [int]$a[0], [int]$a[1], 0x0014) | Out-Null }
  try {
    while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline -and -not $p.HasExited) { Start-Sleep -Milliseconds 300; $p.Refresh(); $hwnd = $p.MainWindowHandle }
    if ($hwnd -ne [IntPtr]::Zero) { SizeTo $Size }
    $afterSeen = $false; $afterStart = $null
    $seen = @{}   # log file -> lines already read
    while ((Get-Date) -lt $deadline) {
      if ($p.HasExited) { Start-Sleep -Milliseconds 400 }
      foreach ($lg in (Get-SessionLogs $Home2)) {
        $lines = @(Get-Content $lg.FullName -ErrorAction SilentlyContinue)
        $from = 0; if ($seen.ContainsKey($lg.FullName)) { $from = $seen[$lg.FullName] }
        for ($i = $from; $i -lt $lines.Count; $i++) {
          $l = $lines[$i]
          if ($l -match '\[SELFTEST\] shot (\S+)') {
            $n = $Matches[1]
            if ($n -like 'size-*') { $curSize = $n.Substring(5); SizeTo $curSize; Start-Sleep -Milliseconds 1200 }
            else {
              [SmokeWin]::Park($hwnd); Start-Sleep -Milliseconds 900
              $png = Join-Path $ShotDir "$n-$curSize.png"
              # The editor window is visible on a machine someone may be using: a capture of a minimized window is the caption
              # only, and a PrintWindow of a window the compositor has not drawn yet is black. Restore and retry a few times.
              for ($try = 0; $try -lt 4; $try++) {
                if ([SmokeWin]::IsIconic($hwnd)) { SizeTo $curSize; Start-Sleep -Milliseconds 1200; [SmokeWin]::Park($hwnd); Start-Sleep -Milliseconds 400 }
                try { [SmokeWin]::Shot($hwnd, $png) } catch { }
                if ((Test-Path $png) -and (Get-Item $png).Length -ge 6000) { break }
                Say "  capture $n-$curSize came back empty (try $($try + 1)); restoring the window and retrying"
                Start-Sleep -Milliseconds 800
              }
              $shotNames.Add("$n-$curSize")
            }
            Set-Content -Path (Join-Path $ShotDir "$n.done") -Value "ok"
          }
          if ($l -match '\[SELFTEST\] done failures=(\d+)') { $res.result = "done failures=$($Matches[1])"; $res.failures = [int]$Matches[1] }
        }
        $seen[$lg.FullName] = $lines.Count
      }
      if ($res.failures -ne $null) {
        # a late answer (the update check runs on a worker thread): wait for it up to 40 s after the run is done
        if ($AfterDonePattern -and -not $afterSeen) {
          if (-not $afterStart) { $afterStart = Get-Date }
          $hit = $false
          foreach ($lg in (Get-SessionLogs $Home2)) { if (@(Get-Content $lg.FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match $AfterDonePattern }).Count -gt 0) { $hit = $true } }
          if ($hit -or ((Get-Date) - $afterStart).TotalSeconds -gt 40) { $afterSeen = $true } else { Start-Sleep -Milliseconds 500; continue }
        }
        break
      }
      if ($p.HasExited) { $res.result = "editor exited early (code $($p.ExitCode))"; break }
      Start-Sleep -Milliseconds 250
    }
  } finally {
    Start-Sleep -Milliseconds 500
    Stop-Pid $p.Id
  }
  $res.seconds = [int]((Get-Date) - $t0).TotalSeconds
  # the log of the run
  $all = @()
  foreach ($lg in (Get-SessionLogs $Home2)) { $all += @(Get-Content $lg.FullName -ErrorAction SilentlyContinue) }
  $logCopy = Join-Path (Split-Path -Parent $ShotDir) "$Name.session.log"
  $all | Set-Content -Path $logCopy -Encoding UTF8
  $res.log = $logCopy
  $res.asserts = @($all | Where-Object { $_ -match '\[ASSERT\]' -and $_ -notmatch 'no host asserts' }).Count
  $res.selftestFails = @($all | Where-Object { $_ -match '\[SELFTEST\] FAIL' } | Select-Object -First 8)
  $res.crash = @(Get-CrashFiles $Home2 | ForEach-Object { $_.Name })
  Get-ChildItem $ShotDir -Filter "*.done" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  $res.shotsRequested = $shotNames.Count
  foreach ($n in $shotNames) {
    $f = Join-Path $ShotDir "$n.png"
    if (-not (Test-Path $f) -or (Get-Item $f).Length -lt 6000) { $res.shotsMissing += $n }
  }
  if ($res.failures -ne 0) { $res.why += "run ended '$($res.result)', not 'done failures=0'" }
  if ($res.asserts -gt 0) { $res.why += "$($res.asserts) [ASSERT] line(s)" }
  if ($res.selftestFails.Count -gt 0) { $res.why += "$($res.selftestFails.Count) [SELFTEST] FAIL line(s)" }
  if ($res.crash.Count -gt 0) { $res.why += "crash report(s): $($res.crash -join ', ')" }
  if ($res.shotsMissing.Count -gt 0) { $res.why += "missing captures: $($res.shotsMissing -join ', ')" }
  $res.ok = ($res.why.Count -eq 0)
  return $res
}

# ---- the scratch project the self-test session expects ----
function New-ScratchProject([string]$dir) {
  if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
  New-Item -ItemType Directory -Force (Join-Path $dir "src") | Out-Null
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $dir "BeefProj.toml"), "FileVersion = 1`r`nDependencies = {corlib = `"*`"}`r`n`r`n[Project]`r`nName = `"VerdictGame`"`r`nStartupObject = `"VerdictGame.Program`"`r`n", $enc)
  [IO.File]::WriteAllText((Join-Path $dir "BeefSpace.toml"), "FileVersion = 1`r`nProjects = {VerdictGame = {Path = `".`"}}`r`n`r`n[Workspace]`r`nStartupProject = `"VerdictGame`"`r`n", $enc)
  $src = @"
using System;

namespace VerdictGame
{
	class GameBase
	{
		public virtual void Tick(float dt)
		{
		}
	}

	class Other
	{
		public int mValue;
	}

	class Program
	{
		public static int Main(String[] args)
		{
			return 0;
		}
	}
}
"@
  [IO.File]::WriteAllText((Join-Path $dir "src\Program.bf"), ($src -replace "`r?`n", "`r`n"), $enc)
}

function Add-Phase([string]$name, [bool]$ok, $detail) {
  $Report.phases += [ordered]@{ name = $name; ok = $ok; detail = $detail }
  Say ("phase $name " + $(if ($ok) { "OK" } else { "FAILED" }))
}

function Get-Sha256([string]$f) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLowerInvariant() }
function Expand-Zip([string]$zip, [string]$dest) {
  New-Item -ItemType Directory -Force $dest | Out-Null
  & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $dest
  if ($LASTEXITCODE -ne 0) { throw "tar could not unpack $zip" }
}

try {
  # ================= verify =================
  $detail = [ordered]@{}
  $zipPath = $null
  if ($Tag) {
    Say "downloading $Tag from $Repo"
    $dl = Join-Path $Work "download"; New-Item -ItemType Directory -Force $dl | Out-Null
    if (-not (Test-Path $Gh)) { throw "gh not found at $Gh" }
    # A draft (not signed yet) has no release.json: gh then exits non-zero and writes to stderr, which must not stop the run.
    try { cmd /c "`"$Gh`" release download $Tag --repo $Repo --dir `"$dl`" --pattern release.json >nul 2>nul" | Out-Null } catch {}
    $zipName = $null
    $rj = Join-Path $dl "release.json"
    if (Test-Path $rj) {
      $d = Get-Content $rj -Raw | ConvertFrom-Json
      $a = @($d.assets | Where-Object { $_.platform -eq "win64" })
      if ($a.Count -eq 1) { $zipName = $a[0].name; $detail.descriptor = "release.json names $zipName" }
    }
    if (-not $zipName) {
      $names = @(& $Gh release view $Tag --repo $Repo --json assets --jq ".assets[].name")
      $c = @($names | Where-Object { $_ -match '^VisualBeef-[0-9.]+-win64\.zip$' })
      if ($c.Count -ne 1) { throw "cannot tell which asset of $Tag is the full win64 zip (candidates: $($c -join ', '))" }
      $zipName = $c[0]; $detail.descriptor = "no win64 entry in release.json; chose $zipName by name"
    }
    & $Gh release download $Tag --repo $Repo --dir $dl --pattern $zipName --pattern "$zipName.sha256"
    if ($LASTEXITCODE -ne 0) { throw "gh release download failed" }
    $zipPath = Join-Path $dl $zipName
  } else {
    $zipPath = (Resolve-Path $Zip).Path
  }
  $sha = Get-Sha256 $zipPath
  $Report.zip = [ordered]@{ name = (Split-Path -Leaf $zipPath); sha256 = $sha; size = (Get-Item $zipPath).Length; source = $(if ($Tag) { "release $Tag of $Repo" } else { "local file" }) }
  $side = "$zipPath.sha256"
  if (Test-Path $side) {
    $listed = ((Get-Content $side -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    if ($listed -eq $sha) { $detail.sha256File = "matches ($listed)" } else { Fail "verify" ".sha256 file says $listed, the zip hashes to $sha"; $detail.sha256File = "MISMATCH" }
  } elseif ($Tag) { Fail "verify" "the release has no .sha256 for the zip"; $detail.sha256File = "missing" }
  else { $detail.sha256File = "no sibling .sha256 (local file)" }
  if ($Tag) {
    $att = & $Gh attestation verify $zipPath --repo $Repo 2>&1
    if ($LASTEXITCODE -eq 0) { $detail.attestation = "gh attestation verify OK" }
    else { Fail "verify" "gh attestation verify failed: $(($att | Out-String).Trim())"; $detail.attestation = "FAILED" }
  } else {
    $detail.attestation = "not checked (a local zip; use -Tag for the release)"
    $Warnings.Add("verify: attestation not checked for a local zip")
  }
  $Install = Join-Path $Work "install"
  Expand-Zip $zipPath $Install
  $Exe = Join-Path $Install "VisualBeefEditor.exe"
  $missing = @("VisualBeefEditor.exe", "vbhost.dll", "LICENSE", "VERSION.txt") | Where-Object { -not (Test-Path (Join-Path $Install $_)) }
  if ($missing) { Fail "verify" "the package lacks: $($missing -join ', ')" }
  $Version = if (Test-Path (Join-Path $Install "VERSION.txt")) { (Get-Content (Join-Path $Install "VERSION.txt") -Raw).Trim() } else { "" }
  $Report.version = $Version
  $detail.version = $Version
  $detail.docsIncluded = Test-Path (Join-Path $Install "docs")
  if (-not $detail.docsIncluded) { Fail "verify" "the full zip has no docs folder (is this the minimal zip?)" }
  if (-not (Test-Path $BeefBuild)) { Fail "verify" "BeefBuild not found at $BeefBuild (the compile checks need it)" }
  Add-Phase "verify" ($Failures.Count -eq 0) $detail
  if ($Failures.Count -gt 0) { throw "the package did not verify; the editor is not run" }

  # ================= version =================
  if ($Phases -contains "version") {
    $n0 = $Failures.Count
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.Arguments = "--version"; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Install; $psi.CreateNoWindow = $true
    $pv = [Diagnostics.Process]::Start($psi); $Started_pids.Add($pv.Id)
    $outText = $pv.StandardOutput.ReadToEnd().Trim()
    if (-not $pv.WaitForExit(30000)) { Stop-Pid $pv.Id; Fail "version" "--version did not exit in 30 s" }
    elseif ($pv.ExitCode -ne 0) { Fail "version" "--version exited with $($pv.ExitCode)" }
    $core = $Version
    if ($outText -notlike "*$core*") { Fail "version" "--version printed '$outText', VERSION.txt says $core" }
    Add-Phase "version" ($Failures.Count -eq $n0) ([ordered]@{ output = $outText })
  }

  # ================= matrix =================
  $Tmpl = Join-Path $Work "template"
  if ($Phases -contains "matrix") {
    $n0 = $Failures.Count
    $runs = @()
    foreach ($theme in @(@{ n = "dark"; v = "0" }, @{ n = "darker"; v = "1" })) {
      foreach ($size in @("1280x800", "1920x1080")) {
        foreach ($scale in @("1", "1.25")) {
          $name = "$($theme.n)-$size-s$scale"
          Say "matrix run $name"
          $proj = Join-Path $Work "proj-$name"; New-ScratchProject $proj
          $r = Invoke-EditorRun -Name $name -Tests "theme:$($theme.v),session" -Project $proj -Home2 (Join-Path $Work "home-$name") -Exe $Exe `
                 -Scale $(if ($scale -eq "1") { "" } else { $scale }) -Size $size -ShotDir (Join-Path $Out "shots\$name") -TimeoutSec 900
          if (-not $r.ok -and $r.why.Count -eq 1 -and $r.why[0] -like "missing captures:*") {
            # The session itself passed; only captures were lost (window minimized or not composed). One repeat, then it counts.
            Say "  $name -> $($r.why[0]); repeating the run once"
            Remove-Item -Recurse -Force $proj -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force (Join-Path $Work "home-$name") -ErrorAction SilentlyContinue
            New-ScratchProject $proj
            $r = Invoke-EditorRun -Name $name -Tests "theme:$($theme.v),session" -Project $proj -Home2 (Join-Path $Work "home-$name") -Exe $Exe `
                   -Scale $(if ($scale -eq "1") { "" } else { $scale }) -Size $size -ShotDir (Join-Path $Out "shots\$name") -TimeoutSec 900
            $r.repeated = $true
          }
          $runs += $r
          if (-not $r.ok) { Fail "matrix" "$name`: $($r.why -join '; ')" }
          elseif ($r.shotsRequested -lt 20) { Fail "matrix" "$name`: only $($r.shotsRequested) captures requested" }
          Say "  $name -> $($r.result), asserts=$($r.asserts), captures=$($r.shotsRequested) (missing $($r.shotsMissing.Count)), $($r.seconds) s"
          Remove-Item -Recurse -Force $proj -ErrorAction SilentlyContinue
          Remove-Item -Recurse -Force (Join-Path $Work "home-$name") -ErrorAction SilentlyContinue
        }
      }
    }
    Add-Phase "matrix" ($Failures.Count -eq $n0) $runs
  }

  # ================= fresh settings first start =================
  if ($Phases -contains "fresh") {
    $n0 = $Failures.Count
    $freshRuns = @()
    # (a) no project at all, empty data folder
    Say "fresh start A: no project (nodoc)"
    $ra = Invoke-EditorRun -Name "fresh-noproject" -Tests "nodoc,startpage,docs" -Project "" -Home2 (Join-Path $Work "home-fresh-a") -Exe $Exe -ShotDir (Join-Path $Out "shots\fresh-noproject") -TimeoutSec 300
    $freshRuns += $ra
    if (-not $ra.ok) { Fail "fresh" "no-project start: $($ra.why -join '; ')" }
    # (b) a project, empty data folder: open a function, Node menu, Preferences > Updates, Check for Updates, then the session (compile)
    Say "fresh start B: project, empty data folder"
    $proj = Join-Path $Work "proj-fresh"; New-ScratchProject $proj
    $tests = "theme:0,session,open:Program.Main(String[]),menu,shot:fresh-node-menu,menu-close,prefs:5,shot:fresh-prefs-updates,update-check,prefs-close"
    $rb = Invoke-EditorRun -Name "fresh-project" -Tests $tests -Project $proj -Home2 (Join-Path $Work "home-fresh-b") -Exe $Exe -ShotDir (Join-Path $Out "shots\fresh-project") -TimeoutSec 900 -AfterDonePattern "is up to date|is available|not set up|was refused|could not be reached|offline"
    $freshRuns += $rb
    if (-not $rb.ok) { Fail "fresh" "project start: $($rb.why -join '; ')" }
    $lines = @(Get-Content $rb.log -ErrorAction SilentlyContinue)
    $answer = ""
    $verdict = "no answer"
    foreach ($l in $lines) {
      if ($l -match 'Updates are not set up') { $verdict = "not set up"; $answer = $l.Trim(); break }
      if ($l -match 'VisualBeef \S+ is up to date') { $verdict = "up to date"; $answer = $l.Trim(); break }
      if ($l -match 'VisualBeef \S+ is available') { $verdict = "available"; $answer = $l.Trim(); break }
      if ($l -match 'The update was refused') { $verdict = "refused"; $answer = $l.Trim(); break }
    }
    if ($verdict -eq "no answer") {
      $u = @($lines | Where-Object { $_ -match '(?i)update|github|offline|reach' } | Select-Object -First 3)
      if ($u.Count -gt 0) { $answer = ($u -join ' | '); $verdict = "unreachable or unclear" }
    }
    $okAnswer = ($verdict -eq "up to date" -or $verdict -eq "available" -or ($AllowOffline -and $verdict -eq "unreachable or unclear"))
    if (-not $okAnswer) { Fail "fresh" "Check for Updates answered '$verdict' ($answer); expected up to date or the next version" }
    $sawCompile = @($lines | Where-Object { $_ -match '(?i)compile|BeefBuild' }).Count -gt 0
    if (-not $sawCompile) { Fail "fresh" "no compile / BeefBuild line in the log of the project start" }
    $freshRuns[1].updateCheck = [ordered]@{ verdict = $verdict; answer = $answer }
    Remove-Item -Recurse -Force $proj -ErrorAction SilentlyContinue
    Add-Phase "fresh" ($Failures.Count -eq $n0) ([ordered]@{ runs = $freshRuns; updateCheck = [ordered]@{ verdict = $verdict; answer = $answer }; beefBuild = $BeefBuild })
  }

  # ================= update end to end =================
  if ($Phases -contains "update") {
    $n0 = $Failures.Count
    $e2e = @()
    $parts = $Version -split '-', 2
    $nums = $parts[0] -split '\.'
    $nextCore = "$($nums[0]).$($nums[1]).$([int]$nums[2] + 1)"
    $nextVersion = if ($parts.Count -gt 1) { "$nextCore-$($parts[1])" } else { $nextCore }
    foreach ($broken in @($false, $true)) {
      $label = if ($broken) { "rollback" } else { "install" }
      Say "update e2e: $label"
      $run = Join-Path $Work "upd-$label"
      New-Item -ItemType Directory -Force "$run\staging\files", "$run\home" | Out-Null
      Expand-Zip $zipPath "$run\install"
      Expand-Zip $zipPath "$run\staging\files"
      Set-Content -Path "$run\staging\files\VERSION.txt" -Value $nextVersion -Encoding ascii
      if ($broken) { Copy-Item "$env:SystemRoot\System32\whoami.exe" "$run\staging\files\VisualBeefEditor.exe" -Force }
      New-ScratchProject "$run\proj"
      Reset-VbEnv
      $env:VB_HOME = "$run\home"; $env:VB_SELFTEST = "update-stage:$run\staging\files"; $env:VB_UPDATE_HEALTH_MS = "15000"
      $p = Start-Ours "$run\install\VisualBeefEditor.exe" "`"$run\proj`"" "$run\install"
      Reset-VbEnv
      $logFile = "$run\home\update\update.log"
      $want = if ($broken) { "previous copy restored" } else { "update complete" }
      $reached = $false
      $deadline = (Get-Date).AddSeconds(180)
      while ((Get-Date) -lt $deadline) {
        if (Test-Path $logFile) {
          $t = Get-Content $logFile -Raw
          if ($t -match [regex]::Escape($want)) { $reached = $true; break }
          if ($t -match "incomplete|failed") { Start-Sleep -Seconds 5; break }
        }
        Start-Sleep -Milliseconds 1000
      }
      Start-Sleep -Seconds 6
      $logText = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { "" }
      $verNow = (Get-Content "$run\install\VERSION.txt" -Raw).Trim()
      $instJson = "$run\home\update\installed.json"
      $inst = if (Test-Path $instJson) { (Get-Content $instJson -Raw).Trim() } else { "" }
      $running = @()
      foreach ($pr in @(Get-Process -Name VisualBeefEditor -ErrorAction SilentlyContinue)) { $pp = $null; try { $pp = $pr.Path } catch {}; if ($pp -and $pp.StartsWith("$run\install", [StringComparison]::OrdinalIgnoreCase)) { $running += $pr.Id } }
      $r = [ordered]@{ name = $label; expectedLog = $want; reached = $reached; installedVersion = $verNow; installedJson = $inst; editorRunningAfter = ($running.Count -gt 0); updateLogTail = (($logText -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6) -join " | "); ok = $false; why = @() }
      if (-not $reached) { $r.why += "update.log never showed '$want'" }
      if ($broken) {
        if ($verNow -ne $Version) { $r.why += "after the rollback VERSION.txt is $verNow, expected $Version" }
        if ($inst -match [regex]::Escape($nextVersion)) { $r.why += "installed.json records the failed version" }
        if ($running.Count -eq 0) { $r.why += "the old editor is not running again after the rollback" }
      } else {
        if ($verNow -ne $nextVersion) { $r.why += "after the update VERSION.txt is $verNow, expected $nextVersion" }
        if (-not $inst) { $r.why += "installed.json was not written" } elseif ($inst -notmatch [regex]::Escape($nextVersion)) { $r.why += "installed.json does not name $nextVersion ($inst)" }
        if ($running.Count -eq 0) { $r.why += "the new editor is not running after the update" }
      }
      foreach ($lg in (Get-SessionLogs "$run\home")) { if (@(Get-Content $lg.FullName | Where-Object { $_ -match '\[ASSERT\]' -and $_ -notmatch 'no host asserts' }).Count -gt 0) { $r.why += "[ASSERT] line in $($lg.Name)" } }
      $crash = @(Get-CrashFiles "$run\home"); if ($crash.Count -gt 0) { $r.why += "crash report(s): $(($crash | ForEach-Object Name) -join ', ')" }
      $r.ok = ($r.why.Count -eq 0)
      if (-not $r.ok) { Fail "update" "$label`: $($r.why -join '; ')" }
      Copy-Item $logFile (Join-Path $Out "update-$label.update.log") -Force -ErrorAction SilentlyContinue
      $stopped = Stop-OursUnder $run
      $r.stoppedPids = $stopped
      $e2e += $r
      Start-Sleep -Seconds 2
      Remove-Item -Recurse -Force $run -ErrorAction SilentlyContinue
    }
    Add-Phase "update" ($Failures.Count -eq $n0) $e2e
  }

  # ================= soak =================
  if ($Phases -contains "soak") {
    $n0 = $Failures.Count
    Say "soak: $SoakSeconds s on the main window"
    $proj = Join-Path $Work "proj-soak"; New-ScratchProject $proj
    $homeS = Join-Path $Work "home-soak"; New-Item -ItemType Directory -Force $homeS | Out-Null
    Reset-VbEnv; $env:VB_HOME = $homeS
    $p = Start-Ours $Exe "`"$proj`"" $Install
    Reset-VbEnv
    $s = [ordered]@{ seconds = $SoakSeconds; samples = 0; notResponding = 0; windowSeen = $false; exitedEarly = $false; workingSetStartMB = 0; workingSetEndMB = 0; exitCode = $null; cleanExit = $false; why = @() }
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $SoakSeconds) {
      Start-Sleep -Seconds 2
      if ($p.HasExited) { $s.exitedEarly = $true; break }
      $p.Refresh()
      if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $s.windowSeen = $true }
      if ($s.windowSeen -and -not $p.Responding) { $s.notResponding++ }
      $s.samples++
      if ($s.samples -eq 3) { $s.workingSetStartMB = [int]($p.WorkingSet64 / 1MB) }
      $s.workingSetEndMB = [int]($p.WorkingSet64 / 1MB)
    }
    if ($s.exitedEarly) { $s.why += "the editor exited after $([int]((Get-Date) - $t0).TotalSeconds) s (code $($p.ExitCode))" }
    else {
      if (-not $s.windowSeen) { $s.why += "no main window appeared" }
      if ($s.notResponding -gt 0) { $s.why += "the window stopped responding in $($s.notResponding) of $($s.samples) samples" }
      $p.CloseMainWindow() | Out-Null
      if ($p.WaitForExit(30000)) { $s.exitCode = $p.ExitCode; $s.cleanExit = ($p.ExitCode -eq 0); if (-not $s.cleanExit) { $s.why += "exit code $($p.ExitCode) after the close message" } }
      else { $s.why += "the editor did not exit within 30 s of the close message"; Stop-Pid $p.Id }
    }
    foreach ($lg in (Get-SessionLogs $homeS)) { if (@(Get-Content $lg.FullName | Where-Object { $_ -match '\[ASSERT\]' -and $_ -notmatch 'no host asserts' }).Count -gt 0) { $s.why += "[ASSERT] line in the session log" } }
    $crash = @(Get-CrashFiles $homeS); if ($crash.Count -gt 0) { $s.why += "crash report(s): $(($crash | ForEach-Object Name) -join ', ')" }
    foreach ($lg in (Get-SessionLogs $homeS | Select-Object -Last 1)) { Copy-Item $lg.FullName (Join-Path $Out "soak.session.log") -Force }
    if ($s.why.Count -gt 0) { Fail "soak" ($s.why -join "; ") }
    Add-Phase "soak" ($Failures.Count -eq $n0) $s
  }
}
catch {
  Fail "smoke" $_.Exception.Message
}
finally {
  Reset-VbEnv
  # Only what this script started, and whatever runs from its scratch folder.
  Stop-OursUnder $Work | Out-Null
  foreach ($id in $Started_pids) { Stop-Pid $id }
  $Report.finishedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $Report.seconds = [int]((Get-Date) - $Started).TotalSeconds
  $Report.failures = @($Failures)
  $Report.warnings = @($Warnings)
  $Report.pidsStarted = @($Started_pids)
  $Report.passed = ($Failures.Count -eq 0 -and $Report.phases.Count -gt 0)
  if (-not $KeepWork) { Start-Sleep -Milliseconds 800; Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
  $prefix = if ($Report.zip.Contains("sha256")) { $Report.zip.sha256.Substring(0, 12) } else { "nozip" }
  $jsonPath = Join-Path $Out "smoke-$prefix.json"
  $mdPath = Join-Path $Out "smoke-$prefix.md"
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($jsonPath, ($Report | ConvertTo-Json -Depth 10), $enc)
  $md = New-Object System.Text.StringBuilder
  $verdict = if ($Report.passed -and $Report.complete) { "PASSED" } elseif ($Report.passed) { "passed (partial run, not accepted by publish)" } else { "FAILED" }
  [void]$md.AppendLine("# VisualBeef release smoke: $verdict")
  [void]$md.AppendLine("")
  [void]$md.AppendLine("* Package: ``$($Report.zip.name)`` ($($Report.zip.source)), version ``$($Report.version)``")
  if ($Report.zip.Contains("sha256")) { [void]$md.AppendLine("* SHA-256: ``$($Report.zip.sha256)``") }
  [void]$md.AppendLine("* Started $($Report.startedAt), $($Report.seconds) s, $($Report.machine)")
  [void]$md.AppendLine("* Complete: $($Report.complete)")
  [void]$md.AppendLine("")
  [void]$md.AppendLine("| Phase | Result |")
  [void]$md.AppendLine("|---|---|")
  foreach ($ph in $Report.phases) { [void]$md.AppendLine("| $($ph.name) | $(if ($ph.ok) { 'ok' } else { 'FAILED' }) |") }
  foreach ($ph in $Report.phases) {
    if ($ph.name -eq "matrix") {
      [void]$md.AppendLine(""); [void]$md.AppendLine("## Session matrix"); [void]$md.AppendLine("")
      [void]$md.AppendLine("| Run | Result | Asserts | Captures | Seconds |"); [void]$md.AppendLine("|---|---|---|---|---|")
      foreach ($r in $ph.detail) { [void]$md.AppendLine("| $($r.name) | $($r.result) | $($r.asserts) | $($r.shotsRequested) (missing $($r.shotsMissing.Count)) | $($r.seconds) |") }
    }
    if ($ph.name -eq "fresh") {
      [void]$md.AppendLine(""); [void]$md.AppendLine("## Fresh settings"); [void]$md.AppendLine("")
      foreach ($r in $ph.detail.runs) { [void]$md.AppendLine("* $($r.name): $($r.result), asserts $($r.asserts), captures $($r.shotsRequested)") }
      [void]$md.AppendLine("* Check for Updates: **$($ph.detail.updateCheck.verdict)** - $($ph.detail.updateCheck.answer)")
    }
    if ($ph.name -eq "update") {
      [void]$md.AppendLine(""); [void]$md.AppendLine("## Update end to end"); [void]$md.AppendLine("")
      foreach ($r in $ph.detail) { [void]$md.AppendLine("* $($r.name): $(if ($r.ok) { 'ok' } else { 'FAILED' }); VERSION.txt $($r.installedVersion); installed.json ``$($r.installedJson)``; log tail: $($r.updateLogTail)") }
    }
    if ($ph.name -eq "soak") {
      [void]$md.AppendLine(""); [void]$md.AppendLine("## Soak"); [void]$md.AppendLine("")
      [void]$md.AppendLine("* $($ph.detail.seconds) s, $($ph.detail.samples) samples, not responding $($ph.detail.notResponding), working set $($ph.detail.workingSetStartMB) -> $($ph.detail.workingSetEndMB) MB, exit code $($ph.detail.exitCode)")
    }
  }
  if ($Failures.Count -gt 0) { [void]$md.AppendLine(""); [void]$md.AppendLine("## Failures"); [void]$md.AppendLine(""); foreach ($f in $Failures) { [void]$md.AppendLine("* $f") } }
  if ($Warnings.Count -gt 0) { [void]$md.AppendLine(""); [void]$md.AppendLine("## Warnings"); [void]$md.AppendLine(""); foreach ($w in $Warnings) { [void]$md.AppendLine("* $w") } }
  [void]$md.AppendLine(""); [void]$md.AppendLine("Processes started: $($Started_pids -join ', ')")
  [IO.File]::WriteAllText($mdPath, $md.ToString(), $enc)
  Say "report: $jsonPath"
  Say "summary: $mdPath"
  Say ("RESULT: " + $verdict)
}
if ($Report.passed) { exit 0 } else { exit 1 }
