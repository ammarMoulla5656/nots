#!/usr/bin/env bash
# Measures قلم المصدر on the phone connected over USB, while you use it.
#
#   tools/perf/phone_perf.sh [seconds] [name]
#
# Every second: the CPU used by each thread of the app (top -H). Before and
# after: its memory (dumpsys meminfo). At the end: the app's speed.log
# ("قياس السرعة" must be on in the account sheet). Everything goes to
# tools/perf/runs/<date>-<name>/, with a summary of the busiest threads:
#   g.alhikmeh.nots  the main thread: the app's own code (building
#                    screens, sync, reading files) runs here
#   2.raster         drawing frames
#   DartWorker       background work (Isolate.run, compute) and the Dart
#                    VM's helpers, all threads of that name added together
#   io.worker        decoding pictures
#   mali-…           the phone's GPU driver
set -euo pipefail
export MSYS_NO_PATHCONV=1

ADB=${ADB:-/d/dev/android-sdk/platform-tools/adb.exe}
PKG=org.alhikmeh.nots
SECS=${1:-30}
NAME=${2:-run}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/runs/$(date +%Y%m%d-%H%M%S)-$NAME"
mkdir -p "$OUT"

PID=$("$ADB" shell pidof "$PKG" | tr -d '\r')
if [ -z "$PID" ]; then
  echo "The app is not running on the phone. Open it, then run this again."
  exit 1
fi
{
  "$ADB" shell getprop ro.product.model
  echo "Android $("$ADB" shell getprop ro.build.version.release)"
  echo "pid $PID, $SECS s"
} | tr -d '\r' > "$OUT/device.txt"
"$ADB" shell dumpsys meminfo "$PKG" | tr -d '\r' > "$OUT/meminfo-before.txt"

echo "Measuring for $SECS s: use the app now…"
for ((i = 1; i <= SECS; i++)); do
  echo "=== $i" >> "$OUT/threads.txt"
  # -b batch, -n 1 one sample, -d 1 over one second, -H threads, -o columns
  "$ADB" shell top -H -b -n 1 -d 1 -p "$PID" -o TID,%CPU,CMD 2>/dev/null \
    | tr -d '\r' | sed -n '/TID/,$p' | tail -n +2 >> "$OUT/threads.txt"
done

"$ADB" shell dumpsys meminfo "$PKG" | tr -d '\r' > "$OUT/meminfo-after.txt"
"$ADB" pull "/sdcard/Android/data/$PKG/files/speed.log" "$OUT/speed.log" >/dev/null 2>&1 \
  || echo "(no speed.log: turn on «قياس السرعة» in the app)" > "$OUT/speed.log"

# Average and highest CPU of each thread over the run.
awk -v secs="$SECS" '
  /^===/ { next }
  NF >= 3 { cpu = $2; $1 = ""; $2 = ""; sub(/^  /, ""); name = $0;
            sum[name] += cpu; if (cpu > max[name]) max[name] = cpu }
  END {
    for (n in sum) printf "%-28s %8.1f %8.1f\n", n, sum[n] / secs, max[n];
  }' "$OUT/threads.txt" | sort -k2 -n -r | awk '$2 > 0' > "$OUT/busy.txt"
{
  printf "%-28s %8s %8s\n" "thread" "avg%" "max%"
  cat "$OUT/busy.txt"
} > "$OUT/summary.txt"

grep -E "TOTAL PSS|TOTAL RSS|Java Heap|Native Heap|Graphics" "$OUT/meminfo-after.txt" \
  >> "$OUT/summary.txt" || true

echo
cat "$OUT/summary.txt" | head -20
echo
echo "Everything is in $OUT"
