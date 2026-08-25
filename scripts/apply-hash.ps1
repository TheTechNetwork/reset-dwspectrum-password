<#
.SYNOPSIS
  apply-hash - run on the LOCKED-OUT DW Spectrum / Nx Witness server.
  Backs up the live database, stops the service, writes the transplanted
  password hash fields onto the target account, restarts the service, and
  verifies it came back healthy.

.DESCRIPTION
  This is step 2 of the hash-transplant recovery (see overview.md). Run
  get-hash on a working server first to produce hash-export.json, copy that
  file to THIS machine, then run this script. It stops the MediaServer service
  briefly (recording pauses, viewers disconnect) and writes to the live
  database only via the real sqlite3.exe tool - never hand-edits binary bytes.

  RUN IT ELEVATED (Administrator) - it stops/starts a Windows service and reads
  the system database under the SYSTEM profile.

  Two ways to run:
    - One-liner (recommended):  irm https://dw.it2.sh/applyhash | iex
      (alias: irm https://dw.it2.sh/ah | iex)
      cd into the folder that holds hash-export.json first: with no -InputFile,
      the script reads hash-export.json from the CURRENT directory, and backups
      / a downloaded sqlite3.exe are written there too.
    - As a saved file:  .\apply-hash.ps1 -TargetAccountName admin
      hash-export.json, backups, etc. are read from / written next to the script.

  To target an account other than 'admin', save the script and run it as a file
  with -TargetAccountName; the one-liner always uses the default account.

.PARAMETER TargetAccountName
  The account on THIS (locked-out) server to overwrite. Default: admin

.PARAMETER InputFile
  Path to the hash-export.json produced by get-hash. Default: hash-export.json
  in the working directory (script folder, or current directory via irm | iex).

.PARAMETER Sqlite3Path
  Path to an existing sqlite3.exe. If omitted, looks in the working directory,
  then downloads the official tool from sqlite.org, and finally falls back to
  https://dw.it2.sh/sqlite3.exe.

.PARAMETER BackupRoot
  Directory to store the pre-edit backup. Default: a 'backups' folder in the
  working directory.

.EXAMPLE
  irm https://dw.it2.sh/applyhash | iex

.EXAMPLE
  .\apply-hash.ps1 -TargetAccountName admin
#>

[CmdletBinding()]
param(
  [string]$TargetAccountName = 'admin',
  [string]$InputFile,
  [string]$Sqlite3Path,
  [string]$BackupRoot
)

$ErrorActionPreference = 'Stop'

# When run as a saved .ps1, $PSScriptRoot is the script's folder. When run via
# `irm https://dw.it2.sh/applyhash | iex` there is no script file, so
# $PSScriptRoot is empty - fall back to the current directory. hash-export.json
# is read from here and backups / a downloaded sqlite3.exe are written here.
$WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $InputFile)  { $InputFile  = Join-Path $WorkDir 'hash-export.json' }
if (-not $BackupRoot) { $BackupRoot = Join-Path $WorkDir 'backups' }

# Shared helpers (Find-*, Ensure-Sqlite3). Dot-sourced from _common.ps1 when this
# runs as a saved .ps1 file; the dw.it2.sh worker inlines _common.ps1's contents
# right here for the `irm | iex` payload.
. (Join-Path $WorkDir '_common.ps1')

Write-Host "=== apply-hash: apply hash to account '$TargetAccountName' ==="
Write-Host "Working directory: $WorkDir"

if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile. Run get-hash on the working server first and copy its hash-export.json here (or pass -InputFile)." }
$import = Get-Content $InputFile -Raw | ConvertFrom-Json

$targetVersion = Find-Version
Write-Host "This server's version:   $targetVersion"
Write-Host "Source server's version: $($import.sourceVersion)"
if ($targetVersion -ne $import.sourceVersion) {
  Write-Warning "Version mismatch ($targetVersion vs $($import.sourceVersion)). The hash format may not be compatible. Proceeding only because you're running this deliberately - verify carefully after restart."
}

$dbPath = Find-SystemDatabase
Write-Host "Database: $dbPath"

$sqlite3 = Ensure-Sqlite3 -PreferredPath $Sqlite3Path
$svc = Find-MediaServerService
Write-Host "Service: $($svc.Name) ($($svc.DisplayName))"

# --- Backup live DB before touching anything ---
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot "preedit-$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
foreach ($suffix in '', '-wal', '-shm') {
  $f = "$dbPath$suffix"
  if (Test-Path $f) { Copy-Item $f -Destination $backupDir -ErrorAction Stop }
}
Write-Host "Backed up live database to: $backupDir"

# --- Stop service ---
Write-Host 'Stopping MediaServer service (recording will pause)...'
Stop-Service -Name $svc.Name -ErrorAction Stop
Start-Sleep -Seconds 2

# --- Apply the update via sqlite3.exe (SQL written to a file, never inlined,
#     since hash values contain $ characters that shells try to expand) ---
$sqlFile = Join-Path $WorkDir 'apply_update.sql'
$sql = @"
UPDATE vms_users
SET digest = '$($import.digest)',
    hash = '$($import.hash)',
    cryptSha512Hash = '$($import.cryptSha512Hash)'
WHERE id = (SELECT r.id FROM vms_resource r WHERE r.name = '$TargetAccountName');
"@
Set-Content -Path $sqlFile -Value $sql -Encoding utf8 -NoNewline
Get-Content $sqlFile -Raw | & $sqlite3 $dbPath
Remove-Item $sqlFile -ErrorAction SilentlyContinue

# --- Verify ---
# Dot-command and SQL passed as separate args, not via a piped file -- see
# the note in get-hash (a file-written BOM breaks dot-command recognition).
$verifySql = "SELECT r.name, u.digest, u.hash, u.cryptSha512Hash FROM vms_users u JOIN vms_resource r ON r.id = u.id WHERE r.name = '$TargetAccountName';"
Write-Host ''
Write-Host '--- verifying write ---'
& $sqlite3 $dbPath '.mode line' $verifySql

# --- Restart service and wait for health ---
Write-Host ''
Write-Host 'Restarting service...'
Start-Service -Name $svc.Name -ErrorAction Stop

$healthy = $false
for ($i = 0; $i -lt 10; $i++) {
  Start-Sleep -Seconds 3
  try {
    $r = Invoke-RestMethod -Uri 'http://localhost:7001/api/moduleInformation' -TimeoutSec 5
    Write-Host "API healthy: $($r.reply.name)"
    $healthy = $true
    break
  } catch { Write-Host "not up yet (try $($i+1))..." }
}
if (-not $healthy) { Write-Warning 'Service did not respond within the wait window - check it manually before assuming failure.' }

Write-Host ''
Write-Host '=== Done ==='
Write-Host "Try logging in as '$TargetAccountName' now."
Write-Host "If it fails, restore from: $backupDir (copy the files back, stop service, replace, start service)."
Write-Host 'If it succeeds: rotate the password immediately (especially if reused from the source server), and delete hash-export.json from both machines.'
