<#
.SYNOPSIS
  apply-default - straight-line recovery that sets a locked-out DW Spectrum /
  Nx Witness account's password to a known value (123456aA) using an
  already-verified hash triplet, instead of running get-hash against a
  reference server each time.

.DESCRIPTION
  The hash values below were extracted (via get-hash) from a working DW
  Spectrum 6.1.0.42176 reference server whose account password is the
  placeholder "123456aA", and have already been confirmed working when applied
  this way. They are version-format-specific - see the check below.

  Sequence: backup live DB (immediately pre-edit) -> stop service -> apply via
  sqlite3.exe -> restart -> verify API health.

  RUN IT ELEVATED (Administrator) - it stops/starts a Windows service and reads
  the system database under the SYSTEM profile.

  Two ways to run:
    - One-liner (recommended):  irm https://dw.it2.sh/applydefault | iex
      (alias: irm https://dw.it2.sh/ad | iex)
      Backups and, if needed, a downloaded sqlite3.exe are written to your
      CURRENT directory - cd to a working folder first.
    - As a saved file:  .\apply-default.ps1 -TargetAccountName admin
      Backups etc. are written next to the script.

  To target an account other than 'admin', save the script and run it as a file
  with -TargetAccountName; the one-liner always uses the default account.

  123456aA is a PLACEHOLDER, not a real security choice - rotate it immediately
  after you regain access.

.PARAMETER TargetAccountName
  Account on this server to overwrite. Default: admin

.PARAMETER Sqlite3Path
  Path to an existing sqlite3.exe. If omitted, looks in the working directory,
  then downloads the official tool from sqlite.org, and finally falls back to
  https://dw.it2.sh/sqlite3.exe.

.PARAMETER BackupRoot
  Directory to store the pre-edit backup. Default: a 'backups' folder in the
  working directory.

.EXAMPLE
  irm https://dw.it2.sh/applydefault | iex

.EXAMPLE
  .\apply-default.ps1 -TargetAccountName admin
#>

[CmdletBinding()]
param(
  [string]$TargetAccountName = 'admin',
  [string]$Sqlite3Path,
  [string]$BackupRoot
)

$ErrorActionPreference = 'Stop'

# When run as a saved .ps1, $PSScriptRoot is the script's folder. When run via
# `irm https://dw.it2.sh/applydefault | iex` there is no script file, so
# $PSScriptRoot is empty - fall back to the current directory. Backups and a
# downloaded sqlite3.exe land here.
$WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $BackupRoot) { $BackupRoot = Join-Path $WorkDir 'backups' }

# Shared helpers (Find-*, Ensure-Sqlite3). Dot-sourced from _common.ps1 when this
# runs as a saved .ps1 file; the dw.it2.sh worker inlines _common.ps1's contents
# right here for the `irm | iex` payload.
. (Join-Path $WorkDir '_common.ps1')

# --- Known-good hash triplet for password: 123456aA ---
# Extracted from a working DW Spectrum 6.1.0.42176 install. If this server is
# on a materially different version, STOP and use the full two-server
# get-hash + apply-hash flow instead - this triplet may not be compatible
# with a different hash format.
$KnownGoodSourceVersion = '6.1.0.42176'
$Digest          = 'http_is_disabled'
$Hash            = 'scrypt$7a7a0cc5$8$1024$16$1c43144ce172aa9bf828a0e52438cb488e8792106572059a343318f4ae99bd30'
$CryptSha512Hash = '$6$C86ymeCH$S2MVpp05uTD3E/guEJRB6S7PF9vHaEx0/nmQFQ8z0.d9GPpziSypEIVVbd8Bj4ZwAHaDykXGPFtwmgW1MG7Dj.'
$KnownPassword   = '123456aA'

Write-Host "=== apply-default: set '$TargetAccountName' to the known password ==="
Write-Host "Working directory: $WorkDir"

$targetVersion = Find-Version
Write-Host "This server's version: $targetVersion"
Write-Host "Hash triplet was generated on: $KnownGoodSourceVersion"
if ($targetVersion -ne $KnownGoodSourceVersion) {
  Write-Warning "Version mismatch. This hash triplet may not apply cleanly here. Consider the get-hash (on a matching-version server) + apply-hash flow instead."
}

$dbPath = Find-SystemDatabase
Write-Host "Database: $dbPath"

$sqlite3 = Ensure-Sqlite3 -PreferredPath $Sqlite3Path
$svc = Find-MediaServerService
Write-Host "Service: $($svc.Name) ($($svc.DisplayName))"

# --- Backup live DB immediately before editing ---
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

# --- Apply (SQL written to a file, never inlined - values contain literal $ characters) ---
$sqlFile = Join-Path $WorkDir 'apply_update.sql'
$sql = @"
UPDATE vms_users
SET digest = '$Digest',
    hash = '$Hash',
    cryptSha512Hash = '$CryptSha512Hash'
WHERE id = (SELECT r.id FROM vms_resource r WHERE r.name = '$TargetAccountName');
"@
Set-Content -Path $sqlFile -Value $sql -Encoding utf8 -NoNewline
Get-Content $sqlFile -Raw | & $sqlite3 $dbPath
Remove-Item $sqlFile -ErrorAction SilentlyContinue

# --- Verify ---
# Dot-command and SQL passed as separate args, not via a piped file:
# Set-Content -Encoding utf8 writes a UTF-8 BOM in Windows PowerShell 5.1,
# and sqlite3 fails to recognize a dot-command on a BOM-prefixed line --
# it gets swallowed into the SQL and errors. Plain SQL (no dot-command,
# like the UPDATE above) tolerates the BOM fine, which is why that step
# still uses the file+pipe technique.
$verifySql = "SELECT r.name, u.digest, u.hash, u.cryptSha512Hash FROM vms_users u JOIN vms_resource r ON r.id = u.id WHERE r.name = '$TargetAccountName';"
Write-Host ''
Write-Host '--- verifying write ---'
& $sqlite3 $dbPath '.mode line' $verifySql

# --- Restart and wait for health ---
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
Write-Host "Log in as '$TargetAccountName' / '$KnownPassword' now."
Write-Host "If it fails, restore from: $backupDir"
Write-Host 'If it succeeds: rotate this password immediately - it is now shared with the reference server it came from.'
