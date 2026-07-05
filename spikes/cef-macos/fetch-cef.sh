#!/usr/bin/env bash
#
# fetch-cef.sh — download + extract a CEF binary distribution for macOS arm64.
#
# Part of the CEF `webEngine:"chromium"` de-risking spike (Task 0). Downloads a
# Spotify automated CEF build (https://cef-builds.spotifycdn.com/) for the
# `macosarm64` platform and extracts it into `spikes/cef-macos/cef_binary/`
# (gitignored). We fetch the `minimal` distribution by default: it ships the
# Release `Chromium Embedded Framework.framework` + the full `include/` tree,
# which is everything the spike links against — no Debug binaries, no prebuilt
# cefclient. That keeps the download ~115 MB compressed instead of ~265 MB.
#
# The ~hundreds-of-MB download is deliberately a HUMAN-RUN step. If running
# unattended is undesirable, invoke via:  ! bash spikes/cef-macos/fetch-cef.sh
#
# Env overrides:
#   CEF_CHANNEL     stable (default) | beta
#   CEF_FILE_TYPE   minimal (default) | standard
#   CEF_VERSION     pin an exact cef_version (default: newest for the channel)
#   RESOLVE_ONLY=1  resolve + print the version/URL, download only the small
#                   index.json, then exit (used to smoke-test this script
#                   without the big tarball).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="macosarm64"
CHANNEL="${CEF_CHANNEL:-stable}"
FILE_TYPE="${CEF_FILE_TYPE:-minimal}"
INDEX_URL="https://cef-builds.spotifycdn.com/index.json"
CDN_BASE="https://cef-builds.spotifycdn.com"
DEST="$HERE/cef_binary"
INDEX_JSON="$HERE/index.json"

command -v python3 >/dev/null || { echo "error: python3 is required to parse the CEF index" >&2; exit 1; }
command -v curl    >/dev/null || { echo "error: curl is required" >&2; exit 1; }
command -v tar     >/dev/null || { echo "error: tar is required" >&2; exit 1; }

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

TARBALL="$HERE/$FILENAME"
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
rm -rf "$DEST"
mkdir -p "$DEST"
# --strip-components=1 drops the top-level cef_binary_<ver>_macosarm64_minimal/
# dir so the distribution's Release/ + include/ land directly under cef_binary/.
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
