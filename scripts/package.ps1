<#
.SYNOPSIS
  Builds the Release editor and assembles a shippable VisualBeef folder (and zip).

.DESCRIPTION
  Output: dist\VisualBeef\ and dist\VisualBeef-<version>-win64.zip (+ .sha256).
  The folder is what UnrealUMP copies to tools\VisualBeef\ (UnrealUMP scripts\package.ps1 -VisualBeef) and what a
  standalone user unzips: VisualBeefEditor.exe, vbhost.dll (the native ImGui/SDL2 host, beside the exe),
  assets\fonts\lucide.ttf, LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY\ (licence texts), docs\ (the user pages only, see below) and
  VERSION.txt (the version from VisualBeefInfo). The Beef runtime is linked statically, so no Beef DLL ships.

  The exe carries an icon (VisualBeefEditor\Resources\VisualBeef.ico) and a VERSIONINFO resource. Beef writes both
  from the [Platform.Windows] section of VisualBeefEditor\BeefProj.toml; this script puts the real version into
  that section for the Release build (and restores the file afterwards), then checks the built exe reports it.

.PARAMETER Minimal
  A blank build that is just the application: VisualBeefEditor.exe, vbhost.dll, assets\, VERSION.txt and the licence
  texts (LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY\). No docs\, README or samples. The folder defaults to
  dist\VisualBeef-minimal and the zip is VisualBeef-<version>-<channel>-win64.zip (channel from VisualBeefInfo.Channel).

.PARAMETER NoBuild
  Package whatever is already in build\Release_Win64 (the exe version check is then skipped).

.PARAMETER Out
  The folder to assemble (default dist\VisualBeef). Use another folder when the default is in use.

.PARAMETER ZipDir
  Where the zip and its .sha256 are written (default dist\). Entry names always use "/".

.PARAMETER SignedDir
  A folder holding code-signed copies of VisualBeefEditor.exe and vbhost.dll (the SignPath result, docs/Code-Signing.md).
  They replace the built files in the package; each must carry a valid Authenticode signature. Use with -NoBuild.

.PARAMETER Clean
  Delete the output folder first.
#>
param(
    [switch]$NoBuild,
    [switch]$Clean,
    [switch]$Minimal,
    [string]$Out = "",
    [string]$ZipDir = "",
    [string]$SignedDir = ""
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
# VB_BEEFBUILD points at another BeefBuild.exe (CI installs Beef into a scratch folder, scripts/ci-windows.ps1).
$BeefBuild = if ($env:VB_BEEFBUILD) { $env:VB_BEEFBUILD } else { "C:\Program Files\BeefLang\bin\BeefBuild.exe" }
$Rel = Join-Path $Repo "build\Release_Win64"
if (-not $Out) { $Out = Join-Path $Repo $(if ($Minimal) { "dist\VisualBeef-minimal" } else { "dist\VisualBeef" }) }
if (-not $ZipDir) { $ZipDir = Join-Path $Repo "dist" }
$Proj = Join-Path $Repo "VisualBeefEditor\BeefProj.toml"

# The version comes from the one place the editor reads it.
$info = [IO.File]::ReadAllText((Join-Path $Repo "VisualBeefCore\src\Document\CommandLine.bf"))
if ($info -notmatch 'public const String Version = "([^"]+)";') { throw "VisualBeefInfo.Version not found in CommandLine.bf" }
$Version = $Matches[1]
if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "VisualBeefInfo.Version '$Version' is not major.minor.patch" }
$major, $minor, $patch = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
if ($info -notmatch 'public const String Channel = "([a-z0-9]+)";') { throw "VisualBeefInfo.Channel not found in CommandLine.bf" }
$Channel = $Matches[1]
$FullVersion = "$Version-$Channel"
$commits = (git -C $Repo rev-list --count HEAD 2>$null)
if (-not $commits) { $commits = 0 }
$FileVersion = "$major.$minor.$patch.$commits"

# Required inputs: licence files that must travel with the binaries (Apache-2.0 LICENSE + NOTICE, third-party texts).
# The root README is the repository page (it links developer documents that do not ship); the package's entry point is docs\Getting-Started.md.
foreach ($f in @("LICENSE", "NOTICE", "THIRD_PARTY.md")) {
    if (-not (Test-Path (Join-Path $Repo $f))) { throw "Missing required file: $f (repo root)" }
}
$ThirdPartyFiles = @("SDL2-LICENSE.txt", "ImGui-LICENSE.txt", "cimgui-LICENSE.txt", "imnodes-LICENSE.txt", "Lucide-LICENSE.txt", "Beef-LICENSE.txt", "Beef-LICENSES.txt", "LLVM-LICENSE.txt", "mingw-w64-runtime-COPYING.txt")
foreach ($f in $ThirdPartyFiles) {
    $p = Join-Path $Repo "THIRD_PARTY\$f"
    if (-not (Test-Path $p) -or (Get-Item $p).Length -lt 200) { throw "Missing or empty third-party licence text: THIRD_PARTY\$f" }
}
$noticeText = [IO.File]::ReadAllText((Join-Path $Repo "NOTICE"))
if ($noticeText -notmatch '(?m)^Copyright\s+(\d{4})\s+(.+?)\s*$') { throw "NOTICE has no 'Copyright <year> <holder>' line" }
$Holder = $Matches[2]

# Refuse a Release build when a Beef file deletes a scope-allocated object (heap corruption in Release).
& (Join-Path $PSScriptRoot "lint-scope-delete.ps1") -Root $Repo
if ($LASTEXITCODE -ne 0) { throw "lint-scope-delete failed: fix the deletes listed above before packaging" }

if (-not $NoBuild) {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Rel "VisualBeefEditor\VisualBeefEditor.exe")
    $original = [IO.File]::ReadAllText($Proj)
    try {
        $stamped = $original -replace '(?m)^FileVersion = "[^"]*"', "FileVersion = `"$FileVersion`""
        $stamped = $stamped -replace '(?m)^ProductVersion = "[^"]*"', "ProductVersion = `"$Version`""
        if (-not $stamped.Contains("FileVersion = `"$FileVersion`"") -or -not $stamped.Contains("ProductVersion = `"$Version`"")) {
            throw "VisualBeefEditor\BeefProj.toml has no FileVersion/ProductVersion lines to stamp"
        }
        [IO.File]::WriteAllText($Proj, $stamped, (New-Object Text.UTF8Encoding($false)))
        Write-Host "== BeefBuild VisualBeefEditor (Release)"
        & $BeefBuild "-workspace=$Repo" -config=Release -platform=Win64 "-project=VisualBeefEditor" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "BeefBuild failed (exit $LASTEXITCODE)" }
    }
    finally {
        [IO.File]::WriteAllText($Proj, $original, (New-Object Text.UTF8Encoding($false)))
    }
}

$exe = Join-Path $Rel "VisualBeefEditor\VisualBeefEditor.exe"
$nativeHost = Join-Path $Repo "Native\bin\win64\vbhost.dll"
$font = Join-Path $Repo "VisualBeefEditor\assets\fonts\lucide.ttf"
$fontLic = Join-Path $Repo "VisualBeefEditor\assets\fonts\LICENSE-lucide.txt"
foreach ($f in @($exe, $nativeHost, $font, $fontLic)) { if (-not (Test-Path $f)) { throw "Missing input: $f" } }
if ($SignedDir) {
    foreach ($n in @("VisualBeefEditor.exe", "vbhost.dll")) {
        $s = Join-Path $SignedDir $n
        if (-not (Test-Path $s)) { throw "-SignedDir has no $n" }
        $sig = Get-AuthenticodeSignature $s
        if ($sig.Status -ne "Valid") { throw "$n in -SignedDir is not validly signed: $($sig.Status)" }
    }
    $exe = Join-Path $SignedDir "VisualBeefEditor.exe"
    $nativeHost = Join-Path $SignedDir "vbhost.dll"
}

$vi = (Get-Item $exe).VersionInfo
# Both signed binaries must report the package version as their ProductVersion (the SignPath readiness rule).
# vbhost.dll's version resource comes from Native\host\vbhost.rc, fed by the same CommandLine.bf constant.
$dllVi = (Get-Item $nativeHost).VersionInfo
foreach ($pair in @(@("VisualBeefEditor.exe", $vi), @("vbhost.dll", $dllVi))) {
    if ($pair[1].ProductVersion -ne $Version) {
        throw "$($pair[0]) ProductVersion is '$($pair[1].ProductVersion)', expected the package version '$Version' (after a version change, rebuild vbhost.dll with Native\build_windows.ps1)"
    }
}
if (-not $NoBuild) {
    if ($vi.ProductVersion -ne $Version -or $vi.FileVersion -ne $FileVersion) {
        throw "VisualBeefEditor.exe VERSIONINFO is '$($vi.FileVersion)' / '$($vi.ProductVersion)', expected '$FileVersion' / '$Version'"
    }
    if ($vi.ProductName -ne "VisualBeef" -or $vi.CompanyName -ne $Holder -or $vi.LegalCopyright -notlike "*$Holder*") {
        throw "VisualBeefEditor.exe VERSIONINFO product/company/copyright is '$($vi.ProductName)' / '$($vi.CompanyName)' / '$($vi.LegalCopyright)', NOTICE says '$Holder' ([Platform.Windows] in VisualBeefEditor\BeefProj.toml)"
    }
} else { Write-Warning "-NoBuild: the exe's version, company and copyright were not checked" }
Add-Type -AssemblyName System.Drawing
if (-not [System.Drawing.Icon]::ExtractAssociatedIcon($exe)) { throw "VisualBeefEditor.exe has no icon" }

if ($Clean -and (Test-Path $Out)) { Remove-Item -Recurse -Force $Out }
foreach ($d in @("assets", "docs", "THIRD_PARTY")) { $p = Join-Path $Out $d; if (Test-Path $p) { Remove-Item -Recurse -Force $p } }
New-Item -ItemType Directory -Force (Join-Path $Out "assets\fonts") | Out-Null
if (-not $Minimal) { New-Item -ItemType Directory -Force (Join-Path $Out "docs") | Out-Null }
New-Item -ItemType Directory -Force (Join-Path $Out "THIRD_PARTY") | Out-Null

Copy-Item $exe (Join-Path $Out "VisualBeefEditor.exe")
Copy-Item $nativeHost (Join-Path $Out "vbhost.dll")
Copy-Item $font (Join-Path $Out "assets\fonts\lucide.ttf")
Copy-Item $fontLic (Join-Path $Out "assets\fonts\LICENSE-lucide.txt")
foreach ($f in @("LICENSE", "NOTICE", "THIRD_PARTY.md")) { Copy-Item (Join-Path $Repo $f) (Join-Path $Out $f) }
# Docs (owner's rule, 2026-10-12): only pages whose front matter says "audience: user" ship. Every page in docs\
# must carry the front matter (audience, title, summary, order) between two --- lines, so none is classified by accident.
$shipDocs = @()
if (-not $Minimal) {
    foreach ($page in Get-ChildItem (Join-Path $Repo "docs") -Filter *.md | Sort-Object Name) {
        $lines = @(Get-Content -LiteralPath $page.FullName -Encoding UTF8)
        if ($lines.Count -lt 3 -or $lines[0] -ne '---') { throw "docs\$($page.Name) has no front matter: every page needs audience: user or audience: developer" }
        $end = [Array]::IndexOf($lines, '---', 1)
        if ($end -lt 2) { throw "docs\$($page.Name): the front matter is not closed by ---" }
        $audience = $null
        foreach ($l in $lines[1..($end - 1)]) { if ($l -match '^audience:\s*(\S+)\s*$') { $audience = $matches[1] } }
        if ($audience -eq 'user') { $shipDocs += $page }
        elseif ($audience -ne 'developer') { throw "docs\$($page.Name): audience is '$audience', expected user or developer" }
    }
    foreach ($page in $shipDocs) { Copy-Item -LiteralPath $page.FullName (Join-Path $Out "docs\$($page.Name)") }
    # Screenshots: only the ones a shipped page shows.
    $imgs = @()
    foreach ($page in $shipDocs) { $imgs += [regex]::Matches((Get-Content -LiteralPath $page.FullName -Raw), 'images/([A-Za-z0-9._-]+\.png)') | ForEach-Object { $_.Groups[1].Value } }
    $imgs = @($imgs | Sort-Object -Unique)
    if ($imgs.Count -gt 0) {
        New-Item -ItemType Directory -Force (Join-Path $Out "docs\images") | Out-Null
        foreach ($img in $imgs) { Copy-Item -LiteralPath (Join-Path $Repo "docs\images\$img") (Join-Path $Out "docs\images\$img") }
    }
    Write-Host "Shipped docs (audience: user), $($shipDocs.Count) pages:"
    foreach ($page in $shipDocs) { Write-Host "  docs\$($page.Name)" }
    Write-Host "Shipped screenshots: $($imgs.Count)"
}
# Check the produced folder: every page in it is a user page, and the developer pages named in the rule are absent.
if (-not $Minimal) {
    $denied = @('Architecture.md', 'Testing.md', 'CI.md', 'Code-Signing.md', 'Codegen.md', 'Parsing-and-Layout.md', 'Catalog-and-Types.md', 'Linux.md', 'UMP-Integration.md', 'Vocabulary.md', 'CHANGELOG.md', 'README.md')
    foreach ($shipped in Get-ChildItem (Join-Path $Out "docs") -Filter *.md) {
        if ($denied -contains $shipped.Name -or $shipped.Name -like '*Audit*') { throw "developer page in the package: docs\$($shipped.Name)" }
        $head = @(Get-Content -LiteralPath $shipped.FullName -TotalCount 6 -Encoding UTF8) -join "`n"
        if ($head -notmatch '(?m)^audience: user\s*$') { throw "docs\$($shipped.Name) in the package does not say audience: user" }
    }
}
foreach ($f in $ThirdPartyFiles) { Copy-Item (Join-Path $Repo "THIRD_PARTY\$f") (Join-Path $Out "THIRD_PARTY\$f") }
Set-Content -Path (Join-Path $Out "VERSION.txt") -Value $FullVersion -Encoding ascii

$forbidden = Get-ChildItem -Recurse $Out -Include *.obj, *.pdb, *.lib, *.ilk, *.exp
if ($forbidden) { throw "Package contains build leftovers: $($forbidden.FullName -join ', ')" }

# The packaged exe must report the version and channel VERSION.txt says (--version needs no window).
$vOut = Join-Path ([IO.Path]::GetTempPath()) ("vb-version-" + [Guid]::NewGuid().ToString("N") + ".txt")
try {
    Start-Process -FilePath (Join-Path $Out "VisualBeefEditor.exe") -ArgumentList "--version" -Wait -NoNewWindow -RedirectStandardOutput $vOut
    $reported = (Get-Content $vOut -TotalCount 1 -ErrorAction SilentlyContinue | Out-String).Trim()
}
finally { Remove-Item -Force -ErrorAction SilentlyContinue $vOut }
if ($reported -notlike "VisualBeef $FullVersion (UMP contract *") { throw "VisualBeefEditor.exe --version printed '$reported', expected 'VisualBeef $FullVersion (UMP contract n)'" }

# Zip: written with System.IO.Compression so entry names use "/" (Compress-Archive in PowerShell 5.1 writes "\").
New-Item -ItemType Directory -Force $ZipDir | Out-Null
$zip = Join-Path $ZipDir $(if ($Minimal) { "VisualBeef-$FullVersion-win64.zip" } else { "VisualBeef-$Version-win64.zip" })
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path $Out).Path.TrimEnd('\')
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in Get-ChildItem -Recurse -Force $root | Sort-Object FullName) {
        $relName = $item.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($item.PSIsContainer) {
            if (-not (Get-ChildItem -Force $item.FullName)) { $archive.CreateEntry("$relName/") | Out-Null }
        } else {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $item.FullName, $relName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
}
finally { $archive.Dispose() }
$check = [System.IO.Compression.ZipFile]::OpenRead($zip)
try { $bad = @($check.Entries | Where-Object { $_.FullName.Contains('\') }) } finally { $check.Dispose() }
if ($bad.Count -gt 0) { throw "Zip entry names contain '\': $($bad[0].FullName)" }

$sha = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Set-Content -Path "$zip.sha256" -Value "$sha  $(Split-Path -Leaf $zip)" -Encoding ascii
Write-Host "Packaged $Out"
Write-Host "Exe version: $($vi.FileVersion) / $($vi.ProductVersion)"
Write-Host "Zip: $zip ($([Math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
Write-Host "SHA-256: $sha"
