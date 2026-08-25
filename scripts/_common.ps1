<#
  _common.ps1 - shared helpers for the DW Spectrum / Nx Witness recovery
  scripts (get-hash, apply-hash, apply-default).

  Each command script dot-sources this file when it runs as a saved .ps1;
  the dw.it2.sh worker inlines this file's contents into the command script
  it serves, so a `irm https://dw.it2.sh/... | iex` payload is complete and
  self-contained with no sibling file required.

  These functions read $WorkDir from the calling script's scope (the script
  folder when saved, or the current directory when piped to iex).
#>

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

function Find-MediaServerService {
  $svc = Get-Service | Where-Object { $_.DisplayName -match 'spectrum|witness|digital watchdog|network optix|media server' } | Select-Object -First 1
  if (-not $svc) { throw "Could not find the MediaServer Windows service. List services and pass its name explicitly if auto-detection fails." }
  return $svc
}

# SHA-256 of the sqlite3.exe pinned at https://dw.it2.sh/sqlite3.exe. The
# fallback download below is verified against this so a wrong or tampered file
# is never used. If the vendored binary in the repo is updated, update this too.
# (Get-FileHash returns uppercase; PowerShell -eq/-ne compare case-insensitively.)
$Sqlite3Sha256 = '5DA2398D4913B893BD1EA578D85403B3A83A06FABF9D2303CA9F63EF0849FC6F'

function Ensure-Sqlite3 {
  # Returns a path to a usable sqlite3.exe, acquiring one if needed:
  #   1. an explicit -PreferredPath, if it exists
  #   2. a sqlite3.exe already sitting in the working directory
  #   3. the official current tools build from sqlite.org
  #   4. the copy pinned on dw.it2.sh/sqlite3.exe (same origin as this script,
  #      so if you reached the script you can reach the tool), SHA-256 verified
  param([string]$PreferredPath)

  if ($PreferredPath -and (Test-Path $PreferredPath)) {
    Write-Host "sqlite3.exe source: -Sqlite3Path -> $PreferredPath"
    return $PreferredPath
  }
  $local = Join-Path $WorkDir 'sqlite3.exe'
  if (Test-Path $local) {
    Write-Host "sqlite3.exe source: existing local copy -> $local"
    return $local
  }

  Write-Host 'sqlite3.exe not found locally - fetching the official tool...'

  # 1) Official sqlite.org download (latest tools build).
  try {
    $page = (Invoke-WebRequest -Uri 'https://sqlite.org/download.html' -UseBasicParsing).Content
    $m = [regex]::Match($page, 'sqlite-tools-win-x64-(\d+)\.zip')
    if ($m.Success) {
      $fileName = $m.Value
      $zipPath  = Join-Path $WorkDir 'sqlite-tools.zip'
      # NOTE: the two candidate years must each be parenthesised. In Windows
      # PowerShell the comma binds tighter than '-', so
      #   @((Get-Date).Year, (Get-Date).Year - 1)
      # parses as (array) - 1 and throws op_Subtraction. Compute once instead.
      $curYear = (Get-Date).Year
      foreach ($year in @($curYear, ($curYear - 1))) {
        $url = "https://www.sqlite.org/$year/$fileName"
        try {
          Write-Host "sqlite3.exe source: downloading from $url"
          Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop | Out-Null
          Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
          $extractDir = Join-Path $WorkDir 'sqlite-tools'
          Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
          $exe = Get-ChildItem $extractDir -Recurse -Filter 'sqlite3.exe' | Select-Object -First 1
          if ($exe) {
            Write-Host "sqlite3.exe source: sqlite.org ($url) -> $($exe.FullName)"
            return $exe.FullName
          }
        } catch { continue }
      }
    }
  } catch { }

  # 2) Fallback: the pinned copy on dw.it2.sh, verified against $Sqlite3Sha256.
  Write-Host 'sqlite.org unavailable - falling back to https://dw.it2.sh/sqlite3.exe ...'
  try {
    Invoke-WebRequest -Uri 'https://dw.it2.sh/sqlite3.exe' -OutFile $local -UseBasicParsing -ErrorAction Stop
    if (Test-Path $local) {
      $actual = (Get-FileHash -Path $local -Algorithm SHA256).Hash
      if ($actual -ne $Sqlite3Sha256) {
        Remove-Item $local -ErrorAction SilentlyContinue
        throw "sqlite3.exe from dw.it2.sh failed SHA-256 check (expected $Sqlite3Sha256, got $actual). Refusing to use it."
      }
      Write-Host "sqlite3.exe source: dw.it2.sh fallback (SHA-256 verified) -> $local"
      return $local
    }
  } catch {
    if ($_.Exception.Message -match 'SHA-256 check') { throw }
  }

  throw "Could not obtain sqlite3.exe (tried sqlite.org and dw.it2.sh/sqlite3.exe). Download it manually, place it in $WorkDir, and re-run."
}
