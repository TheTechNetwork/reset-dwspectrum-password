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
  working directory, and if still not found, downloads the official single-file
  tool from sqlite.org (no installer, public domain).

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

function Find-SystemDatabase {
  $vendorCandidates = @(
    'Digital Watchdog\Digital Watchdog Media Server',
    'Network Optix\Network Optix Media Server'
  )
  $root = 'C:\Windows\System32\config\systemprofile\AppData\Local'
  foreach ($candidate in $vendorCandidates) {
    $p = Join-Path $root "$candidate\ecs.sqlite"
    if (Test-Path $p) { return $p }
  }
  # Fall back to a broader search under the SYSTEM profile
  $found = Get-ChildItem $root -Recurse -Filter 'ecs.sqlite' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.FullName }
  throw "Could not locate ecs.sqlite under $root. Check the MediaServer service account / install."
}

function Find-Version {
  $installRoots = Get-ChildItem 'C:\Program Files' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'digital watchdog|network optix' }
  foreach ($root in $installRoots) {
    # Match only the MediaServer's own build_info.txt -- the same vendor root
    # also contains a Client install with its own build_info.txt (and
    # possibly a nested one under MediaServer\metadata), and "Client" can
    # sort before "MediaServer" in directory enumeration, silently grabbing
    # the wrong version.
    $bi = Get-ChildItem $root.FullName -Recurse -Filter 'build_info.txt' -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match 'MediaServer\\build_info\.txt$' } | Select-Object -First 1
    if ($bi) {
      $line = Get-Content $bi.FullName | Where-Object { $_ -match '^version=' }
      if ($line) { return ($line -replace '^version=','').Trim() }
    }
  }
  return 'unknown'
}

function Ensure-Sqlite3 {
  param([string]$PreferredPath)
  if ($PreferredPath -and (Test-Path $PreferredPath)) { return $PreferredPath }
  $local = Join-Path $WorkDir 'sqlite3.exe'
  if (Test-Path $local) { return $local }

  Write-Host 'sqlite3.exe not found locally - downloading the official tool from sqlite.org...'
  $page = (Invoke-WebRequest -Uri 'https://sqlite.org/download.html' -UseBasicParsing).Content
  $m = [regex]::Match($page, 'sqlite-tools-win-x64-(\d+)\.zip')
  if (-not $m.Success) {
    throw "Could not find the current sqlite-tools filename on the download page. Download it manually from https://sqlite.org/download.html, extract sqlite3.exe into the working directory, and re-run."
  }
  $fileName = $m.Value
  $zipPath = Join-Path $WorkDir 'sqlite-tools.zip'
  $downloaded = $false
  foreach ($year in @((Get-Date).Year, (Get-Date).Year - 1)) {
    $url = "https://www.sqlite.org/$year/$fileName"
    try {
      Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 10 -ErrorAction Stop | Out-Null
      Invoke-WebRequest -Uri $url -OutFile $zipPath -ErrorAction Stop
      $downloaded = $true
      break
    } catch { continue }
  }
  if (-not $downloaded) {
    throw "Could not download $fileName from a recent year-folder on sqlite.org. Download it manually and extract sqlite3.exe into the working directory."
  }
  $extractDir = Join-Path $WorkDir 'sqlite-tools'
  Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
  $exe = Get-ChildItem $extractDir -Recurse -Filter 'sqlite3.exe' | Select-Object -First 1
  if (-not $exe) { throw "sqlite3.exe not found inside the downloaded archive." }
  return $exe.FullName
}

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
