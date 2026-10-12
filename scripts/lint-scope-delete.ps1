<#
.SYNOPSIS
  Fails when Beef code deletes an object it allocated with `scope`.

.DESCRIPTION
  `X = scope ...` puts X on the stack (or in the method's scope arena). `delete X`, `DeleteContainerAndItems!(X)`,
  `DeleteDictionaryAndKeys!(X)` and the other `Delete*!` macros free X itself on the heap: in a Release build that is a
  heap corruption (0xc0000374), not a compile error. Use `ClearAndDeleteItems!(X)` (items only) for a scope container.

  This shipped in another project of the same owner: a data-folder lookup ran DeleteContainerAndItems! on a scope List,
  and every program it started died 1-4 s after start. VisualBeef had the
  same shape in two editor menus (NodeMenu.bf and PropertiesPanel.bf, scope lists of enum cases and flow-macro names);
  both now use ClearAndDeleteItems!. The lint runs in both repos: VisualBeef scripts/package.ps1 calls it before BeefBuild.

  The check is textual: for every `Name = scope` it scans the rest of the enclosing block for a delete of Name, and stops
  early when Name is assigned again. Exit code 1 lists every hit as file:line.

.PARAMETER Root  Repository root (default: the parent of this script's folder).
#>
param([string]$Root = "")

$ErrorActionPreference = "Stop"
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$skip = @('\.git\\', '\\build\\', '\\node_modules\\', '\\recovery\\')
$files = Get-ChildItem -Path $Root -Recurse -File -Filter *.bf | Where-Object {
    $full = $_.FullName
    -not ($skip | Where-Object { $full -match $_ })
}

$decl = [regex]'\b(\w+)\s*=\s*scope\b'
$hits = New-Object System.Collections.ArrayList

foreach ($file in $files) {
    $lines = [IO.File]::ReadAllLines($file.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in $decl.Matches($lines[$i])) {
            $name = [regex]::Escape($m.Groups[1].Value)
            $freed = [regex]"(\bDelete\w*!\(\s*$name\s*\)|\bdelete\s+$name\s*;)"
            $again = [regex]"\b$name\s*=\s*(new|scope)\b"
            # Braces opened after the declaration on its own line count toward the block it lives in.
            $after = $lines[$i].Substring($m.Index)
            $depth = ([regex]::Matches($after, '\{')).Count - ([regex]::Matches($after, '\}')).Count
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $line = $lines[$j]
                if ($again.IsMatch($line)) { break }
                if ($freed.IsMatch($line)) {
                    $rel = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
                    [void]$hits.Add("${rel}:$($j + 1): '$($line.Trim())' deletes '$($m.Groups[1].Value)', allocated with scope at line $($i + 1)")
                }
                $depth += ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
                if ($depth -lt 0) { break } # left the enclosing block: the scope variable is gone
            }
        }
    }
}

if ($hits.Count -gt 0) {
    $hits | ForEach-Object { Write-Output "FAIL: $_" }
    Write-Output "$($hits.Count) delete(s) of scope-allocated objects (use ClearAndDeleteItems! for a scope container)"
    exit 1
}
Write-Output "OK: no delete of a scope-allocated object in $($files.Count) .bf files"
exit 0
