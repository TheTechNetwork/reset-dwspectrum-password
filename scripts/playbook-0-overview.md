# Playbook 0 — Overview: DW Spectrum / Nx Witness Password-Hash Transplant

Three-part playbook for recovering a locked-out local account (typically `admin`)
on a DW Spectrum / Nx Witness server, by copying a password hash from a second,
working server of the same/compatible version — no factory reset needed.

| # | Playbook | Runs on | Purpose |
|---|----------|---------|---------|
| 0 | This file | — | Overview, prerequisites, decision points |
| 1 | `playbook-1-extract-hash.ps1` | **Working** server | Read out an account's password hash fields |
| 2 | `playbook-2-apply-hash.ps1` | **Locked-out** server | Write those fields onto the target account |

Not vendor-documented. Their actual supported path for this scenario is
contacting support/your reseller with proof of license ownership. Use this
when that's too slow or unavailable — treat it as an unsupported workaround,
not a first resort.

## Prerequisites

- OS-level (console/RDP) access to **both** servers.
- The working server is the same DW Spectrum/Nx version as the locked one,
  or as close as possible (exact match best; same `major.minor` next; older
  major versions may use a different hash format entirely — verify before
  relying on it).
- A known password on the working server, for whichever account's hash
  you're transplanting. Two ways to get one:
  - **Use an account whose password you already know** (fastest — skip
    straight to Playbook 1).
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
   Check the `vms_users` table (query in Playbook 1) for other enabled
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
Playbook 1: extract-hash.ps1                     |
  -> reads digest/hash/cryptSha512Hash            |
  -> writes hash-export.json ------copy file----> |
      |                                          |
      |                             Playbook 2: apply-hash.ps1
      |                               -> backs up live DB (x2)
      |                               -> stops service
      |                               -> writes the 3 fields via sqlite3.exe
      |                               -> restarts service, verifies API
      |                                          |
      +--------------- login with the known password on the target account
```

Copy `hash-export.json` between machines by whatever means you'd move any
other file between two servers you administer (USB, file share, RDP
clipboard/drive redirection, etc.) — it contains password hash material,
treat it like a credential in transit (delete it from both machines once
Playbook 2 has run successfully).

## After recovery

- Rotate the password on whichever account you just fixed, especially if
  it was reused from the working server.
- Delete `hash-export.json` from both machines.
- If you created a throwaway account on the working server just to generate
  a known hash, delete/disable it there.
- Keep the pre-edit backup from Playbook 2 until you've confirmed normal
  operation (recording, user logins, camera list) for at least a day.
