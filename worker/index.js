// Cloudflare Worker for dw.it2.sh
//
// Serves the DW Spectrum / Nx Witness password-hash recovery scripts by
// short URL so each can be run in one line:
//
//   irm https://dw.it2.sh/gethash      | iex   # extract hash (working server)
//   irm https://dw.it2.sh/applyhash    | iex   # apply exported hash (locked-out server)
//   irm https://dw.it2.sh/applydefault | iex   # apply the known-good 123456aA hash directly
//
// Each command has a two-letter alias: gh / ah / ad. Matching is
// case-insensitive and ignores a leading slash and .ps1 suffix.
//
// The command scripts keep their shared helpers in scripts/_common.ps1 and
// dot-source it when run as a saved .ps1. For the one-liner there is no sibling
// file, so this Worker inlines _common.ps1 into the served script (replacing the
// dot-source line) - the delivered payload is always complete and self-contained.
//
// /sqlite3.exe serves the vendored copy of the SQLite CLI, which the scripts
// fall back to (SHA-256 verified) when sqlite.org is unreachable.

// Single source of truth: the files live in this repo. Fetched live from the
// default branch so edits there are reflected automatically -- there is no copy
// to keep in sync inside the Worker.
const REPO_RAW =
  "https://raw.githubusercontent.com/TheTechNetwork/reset-dwspectrum-password/main";
const SCRIPTS_BASE = `${REPO_RAW}/scripts`;

// Command (and alias) -> script filename in /scripts.
const ROUTES = {
  gethash:      "get-hash.ps1",
  get:          "get-hash.ps1",
  gh:           "get-hash.ps1",
  applyhash:    "apply-hash.ps1",
  apply:        "apply-hash.ps1",
  ah:           "apply-hash.ps1",
  applydefault: "apply-default.ps1",
  default:      "apply-default.ps1",
  ad:           "apply-default.ps1",
  clean:        "clean.ps1",
  cleanup:      "clean.ps1",
  clear:        "clean.ps1",
  cls:          "clean.ps1",
  c:            "clean.ps1",
  // "…all" variants serve clean.ps1 with -IncludeBackups forced on.
  cleanall:     "clean.ps1",
  cleanupall:   "clean.ps1",
  clearall:     "clean.ps1",
  clsa:         "clean.ps1",
  ca:           "clean.ps1",
};

// Commands that serve clean.ps1 but should also delete the pre-edit DB backups.
// The one-liner can't pass a switch, so the Worker flips the IncludeBackups
// default to $true in the served script for these.
const CLEAN_ALL = new Set(["cleanall", "cleanupall", "clearall", "clsa", "ca"]);
const INCLUDE_BACKUPS_PARAM = /\[switch\]\$IncludeBackups(?!\s*=)/;

// The dot-source line in each command script, replaced with the inlined
// contents of _common.ps1 when serving. Matched leniently (any indentation).
const COMMON_MARKER = /^[^\S\r\n]*\.\s+\(Join-Path \$WorkDir '_common\.ps1'\)[^\r\n]*$/m;

// Human-facing index served at "/" and on an unknown command.
const HELP = `dw.it2.sh - DW Spectrum / Nx Witness password recovery

  irm https://dw.it2.sh/get     | iex    (aliases: gethash, gh)       extract hash on the WORKING server
  irm https://dw.it2.sh/apply   | iex    (aliases: applyhash, ah)     apply exported hash on the LOCKED-OUT server
  irm https://dw.it2.sh/default | iex    (aliases: applydefault, ad)  Apply the known-good 123456aA hash triplet directly
  irm https://dw.it2.sh/clean   | iex    (aliases: cleanup, clear, cls, c)  Remove the working files left behind (keeps DB backups)
  irm https://dw.it2.sh/cleanall| iex    (aliases: cleanupall, clearall, clsa, ca)  Same, but ALSO delete the pre-edit DB backups

Run 'get' on a working server, copy hash-export.json to the locked-out
server, then run 'apply' there. Use 'default' to skip extraction and
apply a pre-verified hash for password 123456aA (rotate it immediately after).

Run these in an ELEVATED PowerShell (Administrator). When piped to iex there is
no script file, so working files (hash-export.json, backups, a downloaded
sqlite3.exe) are written to your current directory -- cd to a working folder
first. All three default to the 'admin' account; to target another account,
save the .ps1 and run it with -AccountName / -TargetAccountName.
`;

async function fetchText(path) {
  // Cache the fetched script hard. These scripts are stable once published, so
  // a long edge cache is fine; when you DO publish an update, purge the
  // Cloudflare cache once (dashboard -> Caching -> Purge, or the API) so the
  // new version replaces the cached one.
  const res = await fetch(`${SCRIPTS_BASE}/${path}`, {
    cf: { cacheTtl: 31536000, cacheEverything: true },
  });
  if (!res.ok) {
    throw new Error(`Failed to fetch ${path} (${res.status})`);
  }
  return res.text();
}

// Fetch the command script and, if it dot-sources _common.ps1, inline that
// file's contents at the marker so the served payload needs no sibling file.
// Scripts without the marker (e.g. clean.ps1) are served as-is, with no
// dependency on _common.ps1.
async function buildScript(fileName) {
  const script = await fetchText(fileName);
  if (!COMMON_MARKER.test(script)) {
    return script;
  }
  const common = await fetchText("_common.ps1");
  const banner =
    "# --- begin inlined _common.ps1 (shared helpers) ---\n" +
    common.replace(/\r?\n$/, "") +
    "\n# --- end inlined _common.ps1 ---";
  return script.replace(COMMON_MARKER, () => banner);
}

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response("OK", { status: 200 });
    }

    // Ignore browser noise
    if (url.pathname === "/favicon.ico") {
      return new Response(null, { status: 204 });
    }

    // Vendored SQLite CLI, streamed from the repo. This is the offline fallback
    // the scripts use (and SHA-256 verify) when sqlite.org is unreachable.
    if (url.pathname === "/sqlite3.exe") {
      const res = await fetch(`${REPO_RAW}/vendor/sqlite3.exe`, {
        cf: { cacheTtl: 86400, cacheEverything: true },
      });
      if (!res.ok) {
        return new Response(`sqlite3.exe not available (${res.status})\n`, { status: 502 });
      }
      return new Response(res.body, {
        status: 200,
        headers: {
          "Content-Type": "application/octet-stream",
          "Content-Disposition": 'attachment; filename="sqlite3.exe"',
          "Cache-Control": "public, max-age=86400",
          "X-Source": "dw.it2.sh",
        },
      });
    }

    // First path segment -> command. Normalise: strip slashes, lowercase,
    // drop an optional .ps1 suffix so /gethash.ps1 works too.
    const segment = url.pathname.replace(/^\/+/, "").replace(/\/+$/, "").split("/")[0];
    const command = decodeURIComponent(segment).toLowerCase().replace(/\.ps1$/, "");

    // Root -> plain-text index of the available commands.
    if (!command) {
      return new Response(HELP, {
        status: 200,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    }

    const fileName = ROUTES[command];
    if (!fileName) {
      return new Response(
        `Unknown command: "${command}".\n\n${HELP}`,
        { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8" } }
      );
    }

    let script;
    try {
      script = await buildScript(fileName);
    } catch (err) {
      return new Response(`${err.message}\n`, { status: 502 });
    }

    // "…all" clean variants: force -IncludeBackups on by flipping the switch
    // default to $true, so the one-liner also removes the pre-edit DB backups.
    if (CLEAN_ALL.has(command)) {
      script = script.replace(INCLUDE_BACKUPS_PARAM, "[switch]$IncludeBackups = $true");
    }

    return new Response(script, {
      status: 200,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        // Published scripts are stable; cache them hard. Purge the Cloudflare
        // cache once when you publish an update so the new version takes over.
        "Cache-Control": "public, max-age=31536000, immutable",
        "X-Source": "dw.it2.sh",
        "X-Command": command,
        "X-Script": fileName,
      },
    });
  },
};
