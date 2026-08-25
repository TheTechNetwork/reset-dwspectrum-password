# dw.it2.sh

A Cloudflare Worker that serves the **DW Spectrum / Nx Witness password-hash
recovery scripts** by short URL, so each can be run in a single line with
`irm ... | iex`. It replaces having to copy full scripts around by hand.

> These are an **unsupported workaround** for recovering a locked-out local
> account (typically `admin`) without a factory reset. The vendor's documented
> path is contacting support/your reseller with proof of license ownership —
> use these only when that's too slow. Read
> [`scripts/overview.md`](scripts/overview.md) first for prerequisites and
> decision points.

## Commands

Each command has a full name and a two-letter alias. Matching is
case-insensitive and tolerates a leading slash, trailing slash, or `.ps1`
suffix.

| Command | Alias | Script | Runs on |
|---------|-------|--------|---------|
| `gethash` | `gh` | [`scripts/get-hash.ps1`](scripts/get-hash.ps1) — extract hash (read-only) | the **working** server |
| `applyhash` | `ah` | [`scripts/apply-hash.ps1`](scripts/apply-hash.ps1) — apply exported hash | the **locked-out** server |
| `applydefault` | `ad` | [`scripts/apply-default.ps1`](scripts/apply-default.ps1) — apply the known `123456aA` hash | the **locked-out** server |

```powershell
# 1) On a WORKING server of the same/compatible version — export a hash:
irm https://dw.it2.sh/gethash | iex        # or: irm https://dw.it2.sh/gh | iex

# 2) Copy the resulting hash-export.json to the locked-out server, then:
irm https://dw.it2.sh/applyhash | iex      # or: irm https://dw.it2.sh/ah | iex
```

Or skip the extraction step entirely and apply a pre-verified hash for the
password `123456aA` (from a DW Spectrum `6.1.0.42176` reference install):

```powershell
irm https://dw.it2.sh/applydefault | iex   # or: irm https://dw.it2.sh/ad | iex
```

Visiting <https://dw.it2.sh> with no path (or an unknown command) returns a
plain-text index of the available commands.

## Running the scripts

- **Run in an elevated PowerShell (Administrator).** The system database lives
  under the SYSTEM account's profile, so a non-elevated shell can't read it —
  and `applyhash` / `applydefault` stop and start a Windows service.
- **PowerShell 5.1 or 7 both work** — no special SDK is required.
- **Where working files go.** When you pipe a script to `iex` there is *no
  script file on disk*, so the scripts write their working files
  (`hash-export.json`, backups, a downloaded `sqlite3.exe`) to your **current
  directory** — `cd` into a working folder first. Run a saved `.ps1` instead and
  those files sit next to the script. Each script prints its working directory
  when it starts.
- **Account.** All three default to the built-in `admin` account. To target a
  different account, download the `.ps1` and run it with `-AccountName`
  (`get-hash`) or `-TargetAccountName` (`apply-hash` / `apply-default`); the
  one-liner form always uses the default account.
- **sqlite3.exe.** The scripts need the SQLite CLI. They look for it in the
  working directory, then download the current build from sqlite.org, and if
  that's unreachable fall back to `https://dw.it2.sh/sqlite3.exe` — a pinned copy
  vendored in this repo. The fallback download is **SHA-256 verified** against a
  hash baked into the script, so a wrong or tampered file is rejected.

> **Rotate the password immediately after recovery** — with `applydefault` the
> hash is shared with the reference server it came from, and with `applyhash`
> it may be reused from the source server. Delete `hash-export.json` from both
> machines once done.

## How it works

- The Worker takes the first path segment (e.g. `/gethash` or `/gh`), normalises
  it (lowercase, strips a leading/trailing slash and an optional `.ps1`), and
  maps it to the matching script.
- The script itself is fetched live from its canonical home in this repo under
  [`scripts/`](scripts/), so edits there are reflected automatically — there is
  no copy kept inside the Worker to keep in sync.
- Shared helpers (`Find-*`, `Ensure-Sqlite3`) live once in
  [`scripts/_common.ps1`](scripts/_common.ps1). Each command script dot-sources
  it when run as a saved `.ps1`; when serving the one-liner the Worker **inlines**
  `_common.ps1` into the script (replacing the dot-source line) so the delivered
  payload is always complete and self-contained.
- `/sqlite3.exe` streams the vendored SQLite CLI from
  [`vendor/sqlite3.exe`](vendor/sqlite3.exe) — the offline fallback described above.
- Unknown commands return `404` with the command index; `/health` returns `OK`.

## Repository layout

| Path | Purpose |
|------|---------|
| `worker/index.js` | The Cloudflare Worker (routing, `_common.ps1` inlining, `/sqlite3.exe`) |
| `wrangler.toml` | Worker config and the `dw.it2.sh` custom-domain route |
| `scripts/overview.md` | Overview, prerequisites, decision points |
| `scripts/get-hash.ps1` | `gethash` / `gh` — extract on the working server |
| `scripts/apply-hash.ps1` | `applyhash` / `ah` — apply on the locked-out server |
| `scripts/apply-default.ps1` | `applydefault` / `ad` — apply the known `123456aA` hash |
| `scripts/_common.ps1` | Shared helpers (`Find-*`, `Ensure-Sqlite3`), inlined when served |
| `vendor/sqlite3.exe` | Pinned SQLite CLI served at `/sqlite3.exe` (SHA-256 verified) |

## Deploying

```bash
npx wrangler deploy
```

The `[[routes]]` entry binds the Worker to the `dw.it2.sh` custom domain. Note
the Worker fetches scripts from the `main` branch, so the routes only serve
successfully once the scripts are present on `main`.
