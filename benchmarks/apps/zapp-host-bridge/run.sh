#!/bin/bash
# Run the host-bridge bench suite N times, aggregate medians, write
# CSV + a markdown table to stdout. Run this after a successful
# `bun install && bun run build` in this directory.
#
#   ./run.sh            # 5 runs (default)
#   ./run.sh 10         # 10 runs
#   ./run.sh 5 --keep   # 5 runs, keep individual logs in /tmp/host-bridge-bench/
set -e

cd "$(dirname "$0")"

RUNS="${1:-5}"
KEEP="${2:-}"
APP="release/bench-host-bridge.app/Contents/MacOS/bench-host-bridge"

if [ ! -x "$APP" ]; then
  echo "package the app first:  bun install && bun run package" >&2
  exit 1
fi

OUTDIR=/tmp/host-bridge-bench
mkdir -p "$OUTDIR"
CSV="$OUTDIR/results.csv"
echo "engine,bench,iters,total_ms,ops_per_sec,us_per_op,run" > "$CSV"

echo "running suite × $RUNS"
for run in $(seq 1 $RUNS); do
  echo "  run $run/$RUNS..."
  # `pkill -9` returns 1 when nothing matches (expected on first run);
  # `|| true` keeps `set -e` happy. Same pattern for the kill below.
  pkill -9 -f bench-host-bridge 2>/dev/null || true
  sleep 1
  log="$OUTDIR/run-$run.log"
  # Launch in background; sleep 8s to let the workers run their suite
  # (each suite is ~3-5s incl. 1.5s grace period); INT to terminate.
  "$APP" > "$log" 2>&1 &
  pid=$!
  sleep 8
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  python3 -c "
import re, sys
with open('$log') as f:
    for line in f:
        m = re.search(r'\[bench:(\S+?)\] (\S[^x]*) x(\d+): ([\d.]+)ms total, ([\d.]+) ops/sec, ([\d.]+) us/op', line)
        if m:
            eng, label, iters, total, ops, us = m.groups()
            print(f'{eng},{label.strip()},{iters},{total},{ops},{us},$run')
" >> "$CSV"
done

if [ "$KEEP" != "--keep" ]; then
  rm -f "$OUTDIR"/run-*.log "$OUTDIR/pid"
fi

# Aggregate medians + ranges, render markdown table.
python3 <<EOF
import csv
from collections import defaultdict
import statistics

data = defaultdict(list)
with open('$CSV') as f:
    r = csv.DictReader(f)
    for row in r:
        data[(row['engine'], row['bench'])].append(float(row['us_per_op']))

# Stable column order — small first, then medium; engine order matches
# zapp.config.ts.
labels = ['invokeService.small', 'invokeService.medium', 'emit.small', 'emit.medium']
engines = ['jsc', 'txiki', 'bare-jsc', 'bare-quickjs', 'bare-v8']
engines = [e for e in engines if any((e, l) in data for l in labels)]

print()
print('## host-bridge bench (median µs/op, range across $RUNS runs)')
print()
print('| engine | ' + ' | '.join(labels) + ' |')
print('|---|' + '---:|' * len(labels))
for e in engines:
    cells = [e]
    for l in labels:
        vals = data.get((e, l), [])
        if vals:
            med = statistics.median(vals)
            mn = min(vals); mx = max(vals)
            cells.append(f'{med:.2f} ({mn:.2f}–{mx:.2f})')
        else:
            cells.append('—')
    print('| ' + ' | '.join(cells) + ' |')
print()
print(f'CSV: $CSV')
EOF
