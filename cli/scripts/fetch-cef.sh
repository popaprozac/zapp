#!/usr/bin/env bash
#
# fetch-cef.sh — download + extract a CEF binary distribution for macOS arm64.
#
# CLI-invoked fetch/cache step for the CEF `webEngine:"chromium"` production
# slice (promoted from spikes/cef-macos/fetch-cef.sh — see
# docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
# design.md). Downloads a Spotify automated CEF build
# (https://cef-builds.spotifycdn.com/) for the `macosarm64` platform and
# extracts the `minimal` distribution (Release framework + include/ tree, the
# whole link surface — no Debug binaries, no prebuilt cefclient; ~115 MB
# compressed instead of ~265 MB) into $CEF_DEST.
#
# Invoked by cli/src/cef.ts (ensureCefFetched) when the CEF cache is missing.
# The ~hundreds-of-MB download can also be a HUMAN-RUN pre-step:
#   CEF_DEST=<vendor>/cef bash cli/scripts/fetch-cef.sh
#
# Env overrides:
#   CEF_DEST        extract destination (default: <script>/../../vendor/cef).
#                   Must end up containing Release/ + include/.
#   CEF_CHANNEL     stable (default) | beta
#   CEF_FILE_TYPE   minimal (default) | standard
#   CEF_VERSION     pin an exact cef_version (default: newest for the channel)
#   RESOLVE_ONLY=1  resolve + print the version/URL, download only the small
#                   index.json, then exit (smoke-test without the big tarball).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="macosarm64"
CHANNEL="${CEF_CHANNEL:-stable}"
FILE_TYPE="${CEF_FILE_TYPE:-minimal}"
INDEX_URL="https://cef-builds.spotifycdn.com/index.json"
CDN_BASE="https://cef-builds.spotifycdn.com"
# Default cache location: the monorepo vendor/ dir (gitignored: vendor/cef/).
DEST="${CEF_DEST:-$HERE/../../vendor/cef}"
INDEX_JSON="$DEST/index.json"

command -v python3 >/dev/null || { echo "error: python3 is required to parse the CEF index" >&2; exit 1; }
command -v curl    >/dev/null || { echo "error: curl is required" >&2; exit 1; }
command -v tar     >/dev/null || { echo "error: tar is required" >&2; exit 1; }

mkdir -p "$DEST"

echo "[fetch-cef] downloading build index ($PLATFORM, channel=$CHANNEL, type=$FILE_TYPE)..."
curl -fSL --retry 3 "$INDEX_URL" -o "$INDEX_JSON"

# Resolve the target file (name + sha1 + cef_version) from the index.
# Prints three tab-separated fields on stdout: <name>\t<sha1>\t<cef_version>
RESOLVED="$(
  CEF_PLATFORM="$PLATFORM" CEF_CHANNEL="$CHANNEL" CEF_FILE_TYPE="$FILE_TYPE" \
  CEF_VERSION="${CEF_VERSION:-}" python3 - "$INDEX_JSON" <<'PY'
import json, os, sys
idx = json.load(open(sys.argv[1]))
plat = os.environ["CEF_PLATFORM"]
channel = os.environ["CEF_CHANNEL"]
ftype = os.environ["CEF_FILE_TYPE"]
pin = os.environ.get("CEF_VERSION") or None

versions = idx.get(plat, {}).get("versions", [])
if not versions:
    sys.exit(f"no versions for platform {plat}")

def pick(v):
    files = {f.get("type"): f for f in v.get("files", [])}
    f = files.get(ftype) or files.get("standard") or files.get("minimal")
    return f

chosen = None
for v in versions:
    if pin:
        if v.get("cef_version") == pin:
            chosen = v; break
    elif v.get("channel") == channel:
        chosen = v; break
if chosen is None:
    sys.exit(f"no build matching channel={channel} version={pin}")

f = pick(chosen)
if not f:
    sys.exit("matched a version but no downloadable file of a usable type")
print("\t".join([f["name"], f.get("sha1", ""), chosen["cef_version"]]))
PY
)"

FILENAME="$(printf '%s' "$RESOLVED" | cut -f1)"
SHA1="$(printf '%s' "$RESOLVED" | cut -f2)"
CEF_VERSION_RESOLVED="$(printf '%s' "$RESOLVED" | cut -f3)"
DOWNLOAD_URL="$CDN_BASE/$FILENAME"

echo "[fetch-cef] resolved cef_version: $CEF_VERSION_RESOLVED"
echo "[fetch-cef] file:                 $FILENAME"
echo "[fetch-cef] url:                  $DOWNLOAD_URL"
echo "[fetch-cef] sha1:                 $SHA1"

if [ "${RESOLVE_ONLY:-0}" = "1" ]; then
  echo "[fetch-cef] RESOLVE_ONLY=1 — not downloading the tarball. Done."
  exit 0
fi

TARBALL="$DEST/$FILENAME"
echo "[fetch-cef] downloading tarball (this is the large step)..."
curl -fSL --retry 3 "$DOWNLOAD_URL" -o "$TARBALL"

if [ -n "$SHA1" ] && command -v shasum >/dev/null; then
  echo "[fetch-cef] verifying sha1..."
  ACTUAL="$(shasum -a 1 "$TARBALL" | awk '{print $1}')"
  if [ "$ACTUAL" != "$SHA1" ]; then
    echo "error: sha1 mismatch (expected $SHA1, got $ACTUAL)" >&2
    exit 1
  fi
  echo "[fetch-cef] sha1 OK"
fi

echo "[fetch-cef] extracting into $DEST ..."
# Extract the distribution's Release/ + include/ directly under $DEST.
# --strip-components=1 drops the top-level cef_binary_<ver>_macosarm64_minimal/
# dir. We DON'T rm -rf $DEST first (it may hold the tarball we just fetched);
# tar overwrites the Release/ + include/ trees in place.
tar xjf "$TARBALL" --strip-components=1 -C "$DEST"

FRAMEWORK="$DEST/Release/Chromium Embedded Framework.framework"
if [ ! -d "$FRAMEWORK" ]; then
  echo "error: extraction did not produce the expected framework at:" >&2
  echo "       $FRAMEWORK" >&2
  echo "       (contents of $DEST:)" >&2
  ls -la "$DEST" >&2 || true
  exit 1
fi

echo "[fetch-cef] done."
echo "[fetch-cef] cef_version:   $CEF_VERSION_RESOLVED"
echo "[fetch-cef] framework:     $FRAMEWORK"
echo "[fetch-cef] headers:       $DEST/include"
echo "[fetch-cef] you can remove the tarball: $TARBALL"
rm -f "$TARBALL"
