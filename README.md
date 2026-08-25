# dw.it2.sh

A Cloudflare Worker that serves the **DW Spectrum / Nx Witness password-hash
recovery playbooks** by short URL, so each can be run in a single line with
`irm ... | iex`. It replaces having to copy full scripts around by hand.

> These are an **unsupported workaround** for recovering a locked-out local
> account (typically `admin`) without a factory reset. The vendor's documented
> path is contacting support/your reseller with proof of license ownership —
> use these only when that's too slow. Read
> [`scripts/playbook-0-overview.md`](scripts/playbook-0-overview.md) first for
> prerequisites and decision points.

## Usage

Each command has a full name and a two-letter alias. Matching is
case-insensitive and tolerates a leading slash, trailing slash, or `.ps1`
suffix.

| Command | Alias | Script | Runs on |
|---------|-------|--------|---------|
| `gethash` | `gh` | Playbook 1 — extract hash (read-only) | the **working** server |
| `applyhash` | `ah` | Playbook 2 — apply exported hash | the **locked-out** server |
| `applydefault` | `ad` | Apply the known-good `123456aA` hash triplet | the **locked-out** server |

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

> **Rotate the password immediately after recovery** — with `applydefault` the
> hash is shared with the reference server it came from, and with `applyhash`
> it may be reused from the source server. Delete `hash-export.json` from both
> machines once done.

Visiting <https://dw.it2.sh> with no path (or an unknown command) returns a
plain-text index of the available commands.

## How it works

- The Worker takes the first path segment (e.g. `/gethash` or `/gh`), normalises
  it (lowercase, strips a leading/trailing slash and an optional `.ps1`), and
  maps it to the matching script.
- The script itself is fetched live from its canonical home in this repo under
  [`scripts/`](scripts/), so edits there are reflected automatically — there is
  no copy kept inside the Worker to keep in sync.
- Unknown commands return `404` with the command index; `/health` returns `OK`.

## Repository layout

| Path | Purpose |
|------|---------|
| `worker/index.js` | The Cloudflare Worker (routing + live fetch) |
| `wrangler.toml` | Worker config and the `dw.it2.sh` custom-domain route |
| `scripts/playbook-0-overview.md` | Overview, prerequisites, decision points |
| `scripts/playbook-1-extract-hash.ps1` | `gethash` / `gh` — extract on the working server |
| `scripts/playbook-2-apply-hash.ps1` | `applyhash` / `ah` — apply on the locked-out server |
| `scripts/apply-known-password.ps1` | `applydefault` / `ad` — apply the known `123456aA` hash |

## Deploying

```bash
npx wrangler deploy
```

The `[[routes]]` entry binds the Worker to the `dw.it2.sh` custom domain.
