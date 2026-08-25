<#
.SYNOPSIS
  Playbook 2 - run on the LOCKED-OUT DW Spectrum / Nx Witness server.
  Backs up the live database, stops the service, writes the transplanted
  password hash fields onto the target account, restarts the service, and
  verifies it came back healthy.

.DESCRIPTION
  Run Playbook 1 on a working server first to produce hash-export.json,
  copy it to this machine, then run this script. It stops the MediaServer
  service briefly (recording pauses, viewers disconnect) and writes to the
  live database only via the real sqlite3.exe tool - never hand-edits
  binary bytes.

.PARAMETER TargetAccountName
  The account on THIS (locked-out) server to overwrite. Default: admin

.PARAMETER InputFile
  Path to the hash-export.json produced by Playbook 1. Default:
  .\hash-export.json (next to this script)

.PARAMETER Sqlite3Path
  Path to an existing sqlite3.exe. If omitted, looks next to this script,
  then downloads the official tool from sqlite.org if still not found.

.PARAMETER BackupRoot
  Directory to store the pre-edit backup. Default: .\backups next to this
  script.

.EXAMPLE
  .\playbook-2-apply-hash.ps1 -TargetAccountName admin
#>

[CmdletBinding()]
param(
  [string]$TargetAccountName = 'admin',
  [string]$InputFile = (Join-Path $PSScriptRoot 'hash-export.json'),
  [string]$Sqlite3Path,
  [string]$BackupRoot = (Join-Path $PSScriptRoot 'backups')
)

$ErrorActionPreference = 'Stop'

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

function Find-MediaServerService {
  $svc = Get-Service | Where-Object { $_.DisplayName -match 'spectrum|witness|digital watchdog|network optix|media server' } | Select-Object -First 1
  if (-not $svc) { throw "Could not find the MediaServer Windows service. List services and pass its name explicitly if auto-detection fails." }
  return $svc
}

function Ensure-Sqlite3 {
  param([string]$PreferredPath)
  if ($PreferredPath -and (Test-Path $PreferredPath)) { return $PreferredPath }
  $local = Join-Path $PSScriptRoot 'sqlite3.exe'
  if (Test-Path $local) { return $local }

  Write-Host 'sqlite3.exe not found locally - downloading the official tool from sqlite.org...'
  $page = (Invoke-WebRequest -Uri 'https://sqlite.org/download.html' -UseBasicParsing).Content
  $m = [regex]::Match($page, 'sqlite-tools-win-x64-(\d+)\.zip')
  if (-not $m.Success) {
    throw "Could not find the current sqlite-tools filename on the download page. Download it manually, extract sqlite3.exe next to this script, and re-run."
  }
  $fileName = $m.Value
  $zipPath = Join-Path $PSScriptRoot 'sqlite-tools.zip'
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
    throw "Could not download $fileName. Download it manually and extract sqlite3.exe next to this script."
  }
  $extractDir = Join-Path $PSScriptRoot 'sqlite-tools'
  Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
  $exe = Get-ChildItem $extractDir -Recurse -Filter 'sqlite3.exe' | Select-Object -First 1
  if (-not $exe) { throw "sqlite3.exe not found inside the downloaded archive." }
  return $exe.FullName
}

Write-Host "=== Playbook 2: apply hash to account '$TargetAccountName' ==="

if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile. Run Playbook 1 on the working server first and copy its output here." }
$import = Get-Content $InputFile -Raw | ConvertFrom-Json

$targetVersion = Find-Version
Write-Host "This server's version:   $targetVersion"
Write-Host "Source server's version: $($import.sourceVersion)"
if ($targetVersion -ne $import.sourceVersion) {
  Write-Warning "Version mismatch ($targetVersion vs $($import.sourceVersion)). The hash format may not be compatible. Proceeding only because you're running this deliberately - verify carefully after restart."
}

$dbPath = Find-SystemDatabase
Write-Host "Database: $dbPath"
$dbDir = Split-Path $dbPath -Parent

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
$sqlFile = Join-Path $PSScriptRoot 'apply_update.sql'
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
# the note in Playbook 1 (a file-written BOM breaks dot-command recognition).
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
