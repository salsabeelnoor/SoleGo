<#
.SYNOPSIS
  Copies schema translation keys that are missing from other languages.

.DESCRIPTION
  Reads locales/en.default.schema.json (the source of truth) and, for every other
  locales/*.schema.json file, adds any key it is missing using the English text.
  This keeps Theme Check's MatchingTranslations check clean after you add a new
  "t:" key for a section, block, or setting.

  Files are edited by inserting lines, so existing formatting, comment headers and
  translations stay untouched. Keys that exist only in other languages are reported
  but never deleted.

.PARAMETER DryRun
  Shows what would be added without changing any file.

.EXAMPLE
  .\scripts\sync-schema-locales.ps1 -DryRun
  .\scripts\sync-schema-locales.ps1
#>
param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$themeRoot = Split-Path -Parent $PSScriptRoot
$localesDir = Join-Path $themeRoot 'locales'
$defaultFile = Join-Path $localesDir 'en.default.schema.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-LocaleJson([string]$path) {
  $text = [IO.File]::ReadAllText($path, $utf8NoBom)
  # Strip the Shopify comment header and whole-line // notes so the JSON parser accepts it.
  $json = $text -replace '^\s*/\*[\s\S]*?\*/', ''
  $json = $json -replace '(?m)^\s*//.*$', ''
  return $json | ConvertFrom-Json
}

# Flattens nested objects into "a.b.c" => "English text".
function Get-FlatKeys($node, [string]$prefix, $result) {
  foreach ($prop in $node.PSObject.Properties) {
    $path = if ($prefix) { "$prefix.$($prop.Name)" } else { $prop.Name }
    if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
      Get-FlatKeys $prop.Value $path $result
    } else {
      $result[$path] = [string]$prop.Value
    }
  }
}

function ConvertTo-JsonString([string]$value) {
  $escaped = $value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
  return '"' + $escaped + '"'
}

# Finds the line index of each object's opening brace, keyed by dotted path ("" = root).
function Get-ObjectLines([string[]]$lines) {
  $map = @{}
  $stack = New-Object System.Collections.Generic.List[string]
  $rootFound = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if (-not $rootFound) {
      if ($line -match '^\s*\{\s*$') { $map[''] = $i; $rootFound = $true }
      continue
    }
    if ($line -match '^\s*"((?:[^"\\]|\\.)*)"\s*:\s*\{\s*$') {
      $stack.Add($Matches[1])
      $map[($stack -join '.')] = $i
    } elseif ($line -match '^\s*\},?\s*$' -and $stack.Count -gt 0) {
      $stack.RemoveAt($stack.Count - 1)
    }
  }
  return $map
}

$defaultKeys = @{}
Get-FlatKeys (Read-LocaleJson $defaultFile) '' $defaultKeys

$targets = Get-ChildItem -Path $localesDir -Filter '*.schema.json' |
  Where-Object { $_.Name -ne 'en.default.schema.json' }

$totalAdded = 0
foreach ($file in $targets) {
  $targetKeys = @{}
  Get-FlatKeys (Read-LocaleJson $file.FullName) '' $targetKeys

  $missing = @($defaultKeys.Keys | Where-Object { -not $targetKeys.ContainsKey($_) } | Sort-Object)
  $extra = @($targetKeys.Keys | Where-Object { -not $defaultKeys.ContainsKey($_) } | Sort-Object)

  foreach ($key in $extra) {
    Write-Host "  [extra] $($file.Name): '$key' is not in en.default.schema.json (left as is)" -ForegroundColor DarkYellow
  }
  if ($missing.Count -eq 0) { continue }

  $text = [IO.File]::ReadAllText($file.FullName, $utf8NoBom)
  $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.AddRange([string[]]($text -split '\r?\n'))

  foreach ($key in $missing) {
    $parts = $key.Split('.')
    $objectLines = Get-ObjectLines $lines.ToArray()

    # Deepest parent object that already exists in this file.
    $depth = $parts.Count - 1
    while ($depth -gt 0 -and -not $objectLines.ContainsKey(($parts[0..($depth - 1)] -join '.'))) { $depth-- }
    $parentPath = if ($depth -gt 0) { $parts[0..($depth - 1)] -join '.' } else { '' }
    $openLine = $objectLines[$parentPath]
    if ($null -eq $openLine) {
      Write-Host "  [skip] $($file.Name): could not find where to add '$key'" -ForegroundColor Red
      continue
    }

    # Build the missing part, nesting new objects when a parent is also missing.
    $indent = ($lines[$openLine] -replace '^(\s*).*$', '$1') + '  '
    $block = New-Object System.Collections.Generic.List[string]
    for ($d = $depth; $d -lt $parts.Count - 1; $d++) {
      $block.Add("$indent$(ConvertTo-JsonString $parts[$d]): {")
      $indent += '  '
    }
    $block.Add("$indent$(ConvertTo-JsonString $parts[-1]): $(ConvertTo-JsonString $defaultKeys[$key])")
    for ($d = $parts.Count - 2; $d -ge $depth; $d--) {
      $indent = $indent.Substring(2)
      $block.Add("$indent}")
    }
    # Inserted first inside the parent, so it needs a comma before the existing members.
    $block[$block.Count - 1] += ','

    $lines.InsertRange($openLine + 1, $block)
    Write-Host "  [add] $($file.Name): $key" -ForegroundColor Green
    $totalAdded++
  }

  if (-not $DryRun) {
    [IO.File]::WriteAllText($file.FullName, ($lines -join $newline), $utf8NoBom)
  }
}

$mode = if ($DryRun) { 'Dry run: would add' } else { 'Added' }
Write-Host "$mode $totalAdded missing key(s) across $($targets.Count) language file(s)."
