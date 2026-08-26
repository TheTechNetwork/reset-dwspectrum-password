<#
.SYNOPSIS
  clean - remove the working files the DW Spectrum / Nx Witness recovery scripts
  leave in a directory: a downloaded sqlite3.exe and its download scaffolding,
  the hash-export.json handoff, and the transient SQL file.

.DESCRIPTION
  Run this in the same directory (and same elevation) you ran get / apply /
  default from. By default it KEEPS the pre-edit database backups - that's your
  restore point - and only removes the scratch/handoff files. Pass
  -IncludeBackups to also delete the backups once the server is confirmed
  healthy.

  Two ways to run:
    - One-liner:  irm https://dw.it2.sh/clean | iex
      (aliases: /cleanup /clear /cls /c)
    - As a saved file:  .\clean.ps1 [-IncludeBackups]

  To include backups from the one-liner (no saved file), invoke the fetched
  text as a scriptblock:
    & ([scriptblock]::Create((irm https://dw.it2.sh/clean))) -IncludeBackups

.PARAMETER IncludeBackups
  Also delete the backups/ folder (pre-edit ecs.sqlite copies). Off by default.
#>

[CmdletBinding()]
param(
  [switch]$IncludeBackups
)

$ErrorActionPreference = 'Stop'

# Same working-directory rule as the other scripts: the script folder when saved,
# or the current directory when piped to iex.
$WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

Write-Host '=== clean: remove recovery working files ==='
Write-Host "Working directory: $WorkDir"

# The scratch/handoff files the recovery scripts create.
$targets = @(
  'sqlite3.exe',
  'sqlite-tools.zip',
  'sqlite-tools',
  'apply_update.sql',
  'hash-export.json'
)

$removed = 0
foreach ($name in $targets) {
  $path = Join-Path $WorkDir $name
  if (Test-Path $path) {
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $path) {
      Write-Warning "could not remove: $path"
    } else {
      Write-Host "removed: $name"
      $removed++
    }
  }
}

# Pre-edit DB backups: kept unless -IncludeBackups is passed.
$backupDir = Join-Path $WorkDir 'backups'
if (Test-Path $backupDir) {
  if ($IncludeBackups) {
    Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $backupDir) {
      Write-Warning "could not remove: $backupDir"
    } else {
      Write-Host 'removed: backups (pre-edit DB copies)'
      $removed++
    }
  } else {
    Write-Host ''
    Write-Warning "Kept the pre-edit DB backups in: $backupDir"
    Write-Host 'That is your restore point. Once the server is confirmed healthy, delete them with:'
    Write-Host "  Remove-Item '$backupDir' -Recurse -Force"
    Write-Host '  (or save clean.ps1 and run:  .\clean.ps1 -IncludeBackups)'
  }
}

Write-Host ''
if ($removed -eq 0) {
  Write-Host '=== Nothing to clean - no recovery working files found here. ==='
} else {
  Write-Host "=== Done - removed $removed item(s). ==="
}
