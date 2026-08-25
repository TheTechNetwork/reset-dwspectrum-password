// Cloudflare Worker for dw.it2.sh
//
// Serves the DW Spectrum / Nx Witness password-hash recovery playbooks by
// short URL so each can be run in one line:
//
//   irm https://dw.it2.sh/gethash      | iex   # extract hash (working server)
//   irm https://dw.it2.sh/applyhash    | iex   # apply exported hash (locked-out server)
//   irm https://dw.it2.sh/applydefault | iex   # apply the known-good 123456aA hash directly
//
// Each command has a two-letter alias: gh / ah / ad. Matching is
// case-insensitive and ignores a leading slash and .ps1 suffix.

// Single source of truth: the scripts live in this repo. Fetched live from
// the default branch so edits there are reflected automatically -- there is
// no copy to keep in sync inside the Worker.
const RAW_BASE =
  "https://raw.githubusercontent.com/TheTechNetwork/reset-dwspectrum-password/main/scripts";

// Command (and alias) -> script filename in /scripts.
const ROUTES = {
  gethash:      "get-hash.ps1",
  gh:           "get-hash.ps1",
  applyhash:    "apply-hash.ps1",
  ah:           "apply-hash.ps1",
  applydefault: "apply-default.ps1",
  ad:           "apply-default.ps1",
};

// Human-facing index served at "/" and on an unknown command.
const HELP = `dw.it2.sh - DW Spectrum / Nx Witness password recovery

  irm https://dw.it2.sh/gethash      | iex    (alias: gh)  extract hash on the WORKING server
  irm https://dw.it2.sh/applyhash    | iex    (alias: ah)  apply exported hash on the LOCKED-OUT server
  irm https://dw.it2.sh/applydefault | iex    (alias: ad)  Apply the known-good 123456aA hash triplet directly

Run 'gethash' on a working server, copy hash-export.json to the locked-out
server, then run 'applyhash' there. Use 'applydefault' to skip extraction and
apply a pre-verified hash for password 123456aA (rotate it immediately after).

Run these in an ELEVATED PowerShell (Administrator). When piped to iex there is
no script file, so working files (hash-export.json, backups, a downloaded
sqlite3.exe) are written to your current directory -- cd to a working folder
first. All three default to the 'admin' account; to target another account,
save the .ps1 and run it with -AccountName / -TargetAccountName.
`;

async function fetchScript(fileName) {
  const res = await fetch(`${RAW_BASE}/${fileName}`, {
    cf: { cacheTtl: 300, cacheEverything: true },
  });
  if (!res.ok) {
    throw new Error(`Failed to fetch ${fileName} (${res.status})`);
  }
  return res.text();
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
      script = await fetchScript(fileName);
    } catch (err) {
      return new Response(`${err.message}\n`, { status: 502 });
    }

    return new Response(script, {
      status: 200,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "public, max-age=300",
        "X-Source": "dw.it2.sh",
        "X-Command": command,
        "X-Script": fileName,
      },
    });
  },
};
