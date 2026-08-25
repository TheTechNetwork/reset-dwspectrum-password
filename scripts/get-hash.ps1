<#
.SYNOPSIS
  get-hash - run on the WORKING DW Spectrum / Nx Witness server.
  Read-only. Extracts one account's password hash fields so they can be
  transplanted onto a locked-out server's account via apply-hash.

.DESCRIPTION
  This is step 1 of the hash-transplant recovery (see overview.md). Before
  running it: on THIS (working) server, either
    (a) pick an account whose password you already know, or
    (b) create a throwaway low-privilege account via the Client/web UI and
        set its password to a known value by hand (not scripted).
  Then run this script naming that account. It never writes to the database -
  strictly a SELECT against the local system database - and it writes a single
  hash-export.json handoff file for apply-hash.

  RUN IT ELEVATED (Administrator). The system database lives under the SYSTEM
  account's profile, so a non-elevated shell cannot read it.

  Two ways to run:
    - One-liner (recommended):  irm https://dw.it2.sh/gethash | iex
      (alias: irm https://dw.it2.sh/gh | iex)
      hash-export.json and, if needed, sqlite3.exe are written to your CURRENT
      directory - cd to a working folder first.
    - As a saved file:  .\get-hash.ps1 -AccountName admin
      Files are written next to the script.

  To target an account other than 'admin', save the script and run it as a file
  with -AccountName; the one-liner always uses the default account.

.PARAMETER AccountName
  The local account name whose hash fields to extract. Default: admin

.PARAMETER OutputFile
  Where to write the JSON handoff file for apply-hash. Default:
  hash-export.json in the working directory (script folder, or current
  directory when run via irm | iex).

.PARAMETER Sqlite3Path
  Path to an existing sqlite3.exe. If omitted, the script looks for one in the
  working directory, then downloads the official tool from sqlite.org, and
  finally falls back to https://dw.it2.sh/sqlite3.exe.

.EXAMPLE
  irm https://dw.it2.sh/gethash | iex

.EXAMPLE
  .\get-hash.ps1 -AccountName admin
#>

[CmdletBinding()]
param(
  [string]$AccountName = 'admin',
  [string]$OutputFile,
  [string]$Sqlite3Path
)

$ErrorActionPreference = 'Stop'

# When run as a saved .ps1, $PSScriptRoot is the script's folder. When run via
# `irm https://dw.it2.sh/gethash | iex` there is no script file, so
# $PSScriptRoot is empty - fall back to the current directory. All working
# files (hash-export.json, a downloaded sqlite3.exe) land here.
$WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $OutputFile) { $OutputFile = Join-Path $WorkDir 'hash-export.json' }

# Shared helpers (Find-SystemDatabase, Find-Version, Ensure-Sqlite3). Dot-sourced
# from _common.ps1 when this runs as a saved .ps1 file; the dw.it2.sh worker
# inlines _common.ps1's contents right here for the `irm | iex` payload.
. (Join-Path $WorkDir '_common.ps1')

Write-Host "=== get-hash: extract hash for account '$AccountName' ==="
Write-Host "Working directory: $WorkDir"

$dbPath = Find-SystemDatabase
Write-Host "Database: $dbPath"

$version = Find-Version
Write-Host "DW Spectrum / Nx Witness version: $version"
Write-Host 'Record this version - apply-hash needs a matching (or close) version on the target server.'

$sqlite3 = Ensure-Sqlite3 -PreferredPath $Sqlite3Path

# NOTE: the dot-command (.mode json) and the SQL are passed as separate
# command-line arguments, not written to a file and piped. Writing them
# together to a file via Set-Content adds a UTF-8 BOM in Windows
# PowerShell 5.1, and sqlite3 fails to recognize a dot-command whose line
# is preceded by that BOM -- it gets swallowed into the SQL and errors.
# Plain SQL (no dot-command) tolerates the BOM fine, which is why the
# actual password UPDATE in apply-hash uses the file+pipe technique, but
# this JSON-mode SELECT must not.
$selectSql = "SELECT r.id, r.name, u.type, u.isEnabled, u.permissions, u.digest, u.hash, u.cryptSha512Hash FROM vms_users u JOIN vms_resource r ON r.id = u.id WHERE r.name = '$AccountName';"
$jsonResult = & $sqlite3 $dbPath '.mode json' $selectSql

if (-not $jsonResult) {
  throw "No account named '$AccountName' found. Check the name and try again."
}

$row = ($jsonResult | ConvertFrom-Json)[0]

if ($row.type -eq 2) {
  Write-Warning "Account '$AccountName' is Cloud-linked (type=2). Its digest/hash fields are placeholders ('password_is_in_cloud') - there is no local secret to extract. Pick a LOCAL account instead."
}

Write-Host ''
Write-Host "id:               $($row.id)"
Write-Host "name:             $($row.name)"
Write-Host "type:             $($row.type)"
Write-Host "isEnabled:        $($row.isEnabled)"
Write-Host "permissions:      $($row.permissions)"
Write-Host "digest:           $($row.digest)"
Write-Host "hash:             $($row.hash)"
Write-Host "cryptSha512Hash:  $($row.cryptSha512Hash)"

$export = [ordered]@{
  sourceAccountName = $row.name
  sourceVersion     = $version
  digest            = $row.digest
  hash              = $row.hash
  cryptSha512Hash   = $row.cryptSha512Hash
}
$export | ConvertTo-Json | Set-Content -Path $OutputFile -Encoding utf8

Write-Host ''
Write-Host "Written to: $OutputFile"
Write-Host 'Copy this file to the locked-out server and run apply-hash there (irm https://dw.it2.sh/applyhash | iex).'
Write-Host 'Treat it like a credential in transit - delete it from both machines once apply-hash succeeds.'
