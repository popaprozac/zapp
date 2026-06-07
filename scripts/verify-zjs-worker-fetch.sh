#!/usr/bin/env bash
# Verify whether fetch().then(r=>r.text()).then(...) resolves end-to-end in an
# EMBEDDED zjs worker (the path the standalone `zjs` CLI does NOT exercise).
#
# Usage:
#   scripts/verify-zjs-worker-fetch.sh            # rebuild current vendor/zjs + test
#   scripts/verify-zjs-worker-fetch.sh <git-ref>  # fetch + checkout that zjs ref first
#
# Reports PASS (then2 fired) or FAIL (then2 never fired) and always restores
# the working tree (ticker.ts probe is reverted).
set -uo pipefail
ZAPP="$(cd "$(dirname "$0")/.." && pwd)"
HW="$ZAPP/hello-world"
TICKER="$HW/src/workers/ticker.ts"
REF="${1:-}"

cd "$ZAPP"

if [ -n "$REF" ]; then
  echo "[verify] vendor/zjs: fetch origin + checkout $REF"
  git -C vendor/zjs fetch origin 2>&1 | tail -1
  git -C vendor/zjs checkout "$REF" 2>&1 | tail -1 || { echo "[verify] FAIL: bad ref"; exit 1; }
fi
echo "[verify] vendor/zjs @ $(git -C vendor/zjs rev-parse --short HEAD)"

echo "[verify] clean-rebuild libzjs (~60s)..."
make -C vendor/zjs clean >/dev/null 2>&1
if ! make -C vendor/zjs >/tmp/verify_zjs_build.log 2>&1; then
  echo "[verify] FAIL: libzjs build error:"; tail -8 /tmp/verify_zjs_build.log; exit 1
fi

echo "[verify] inject fetch-chain probe into ticker.ts"
cp "$TICKER" /tmp/verify_ticker.bak
PROBE='fetch("https://www.google.com").then((r)=>{console.log("VERIFY then1 status",r.status);return r.text();}).then((t)=>console.log("VERIFY then2 len",t.length)).catch((e)=>console.log("VERIFY err",String(e)));'
awk -v probe="$PROBE" '
  { print }
  /from "@zappdev\/runtime"/ && !done { print probe; done=1 }
' /tmp/verify_ticker.bak > "$TICKER"

restore() { cp /tmp/verify_ticker.bak "$TICKER"; }
trap restore EXIT

echo "[verify] rebuild app"
if ! ( cd "$HW" && bun run build >/tmp/verify_app_build.log 2>&1 ); then
  echo "[verify] FAIL: app build error:"; tail -8 /tmp/verify_app_build.log; exit 1
fi

echo "[verify] run app headless (~12s)"
pkill -f 'bin/hello-world' 2>/dev/null
rm -f /tmp/verify_run.log
ZAPP_LOG=debug "$HW/bin/hello-world" >/tmp/verify_run.log 2>&1 &
for i in $(seq 1 24); do sleep 0.5; grep -qE 'VERIFY (then2|err)' /tmp/verify_run.log && break; done
pkill -f 'bin/hello-world' 2>/dev/null

echo "[verify] === markers ==="
grep VERIFY /tmp/verify_run.log || echo "(no VERIFY output — worker may not have started)"
echo "[verify] ==============="
if grep -q 'VERIFY then2' /tmp/verify_run.log; then
  echo "[verify] PASS ✅  fetch().then(r=>r.text()).then() resolved in the zjs worker"
  exit 0
else
  echo "[verify] FAIL ❌  then2 never fired — host-promise adoption bug still present"
  exit 2
fi
