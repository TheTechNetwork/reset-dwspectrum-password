# Overview — DW Spectrum / Nx Witness Password-Hash Transplant

Recover a locked-out local account (typically `admin`) on a DW Spectrum /
Nx Witness server by copying a password hash from a second, working server of
the same/compatible version — no factory reset needed.

Each script has a short URL on `dw.it2.sh` so it can be run in one line with
`irm ... | iex`, plus longer aliases:

| Script | URL command | Aliases | Runs on | Purpose |
|--------|-------------|---------|---------|---------|
| `get-hash.ps1` | `/get` | `/gethash`, `/gh` | **Working** server | Read out an account's password hash fields (read-only) |
| `apply-hash.ps1` | `/apply` | `/applyhash`, `/ah` | **Locked-out** server | Write those fields onto the target account |
| `apply-default.ps1` | `/default` | `/applydefault`, `/ad` | **Locked-out** server | Apply a pre-verified hash for password `123456aA`, skipping extraction |
| `clean.ps1` | `/clean` | `/cleanup`, `/clear`, `/cls`, `/c` | Either server | Remove the working files a run leaves behind (keeps DB backups by default) |
| `clean.ps1` | `/cleanall` | `/cleanupall`, `/clearall`, `/clsa`, `/ca` | Either server | Same, but also delete the pre-edit DB backups |

```powershell
# On the WORKING server:
irm https://dw.it2.sh/get | iex     # aliases: /gethash, /gh
# copy hash-export.json to the locked-out server, then on IT:
irm https://dw.it2.sh/apply | iex   # aliases: /applyhash, /ah
```

Not vendor-documented. Their actual supported path for this scenario is
contacting support/your reseller with proof of license ownership. Use this
when that's too slow or unavailable — treat it as an unsupported workaround,
not a first resort.

## Running the scripts

- **Run in an elevated PowerShell (Administrator).** The system database lives
  under the SYSTEM account's profile; a non-elevated shell can't read it, and
  `apply-hash` / `apply-default` stop and start a Windows service.
- **Works on Windows PowerShell 5.1 and PowerShell 7** — no special SDK needed.
- **Where files go:** run as a saved `.ps1` and working files (hash-export.json,
  backups, a downloaded `sqlite3.exe`) sit next to the script. Run via
  `irm ... | iex` and there is no script file, so they go to your **current
  directory** — `cd` into a working folder first. Each script prints its
  working directory when it starts.
- **Account:** all three default to `admin`. To target a different account,
  save the `.ps1` and run it with `-AccountName` (get-hash) or
  `-TargetAccountName` (apply-hash / apply-default); the one-liner always uses
  the default.

## Prerequisites

- OS-level (console/RDP) access to **both** servers.
- The working server is the same DW Spectrum/Nx version as the locked one,
  or as close as possible (exact match best; same `major.minor` next; older
  major versions may use a different hash format entirely — verify before
  relying on it).
- A known password on the working server, for whichever account's hash
  you're transplanting. Two ways to get one:
  - **Use an account whose password you already know** (fastest — skip
    straight to `get-hash`).
  - **Or set one deliberately**, via the DW Spectrum Client/web UI (not
    scripted — do this by hand), on a throwaway low-privilege test account
    if you don't want to touch anything real on the working server. A
    reasonable example value is `123456aA` — treat it as a placeholder,
    not a real security choice; rotate it immediately after recovery,
    especially since it'll now work on two systems if reused.

## Decision points — check these before reaching for this playbook

1. **Cloud-linked system with a reachable cloud account?** Check
   `GET http://localhost:7001/api/moduleInformation` (no auth needed) for a
   populated `cloudSystemId`/`cloudOwnerId`. If you can log into that cloud
   account, reset the password through the app itself — no scripts needed.
2. **Does another already-working local/cloud user have admin rights?**
   Check the `vms_users` table (query in `get-hash`) for other enabled
   accounts with elevated `permissions`. If you know one's credentials,
   use it through the UI instead.
3. **Vendor support** — the actually-documented path, worth running in
   parallel if time allows.
4. **This playbook** — hash transplant, if 1–3 aren't available and a
   factory reset is unacceptable.
5. **Factory reset** — last resort; wipes local users/cameras/layouts
   (recordings on disk are generally recoverable by re-adding cameras).

## Flow

```
[Working server]                          [Locked-out server]
      |                                          |
get-hash.ps1  (/get)                             |
  -> reads digest/hash/cryptSha512Hash           |
  -> writes hash-export.json ------copy file----> |
      |                                          |
      |                        apply-hash.ps1  (/apply)
      |                          -> backs up live DB
      |                          -> stops service
      |                          -> writes the 3 fields via sqlite3.exe
      |                          -> restarts service, verifies API
      |                                          |
      +--------------- login with the known password on the target account
```

`apply-default.ps1` (`/default`) collapses this to a single step
on the locked-out server when the known-good `123456aA` hash applies to your
version — no working server or `hash-export.json` needed.

Copy `hash-export.json` between machines by whatever means you'd move any
other file between two servers you administer (USB, file share, RDP
clipboard/drive redirection, etc.) — it contains password hash material,
treat it like a credential in transit (delete it from both machines once
`apply-hash` has run successfully).

## After recovery

- Rotate the password on whichever account you just fixed, especially if
  it was reused from the working server.
- Delete `hash-export.json` from both machines. Running `/clean`
  (`irm https://dw.it2.sh/clean | iex`) in the working directory removes it
  along with the other scratch files (`sqlite3.exe` and its download
  scaffolding, the transient SQL file).
- If you created a throwaway account on the working server just to generate
  a known hash, delete/disable it there.
- Keep the pre-edit backup from `apply-hash` until you've confirmed normal
  operation (recording, user logins, camera list) for at least a day. `/clean`
  keeps that backup by default; once you're satisfied, `/cleanall`
  (`irm https://dw.it2.sh/cleanall | iex`) removes everything including the
  backups.
