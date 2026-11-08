#!/usr/bin/env bash
# Adds every PDF of /sdcard/Download/اختبار_10GB to قلم المصدر through its
# own «إضافة كتاب», as a finger would. The folder is shown with one file at a
# time, so the picker's first row is always the one to take.
#
#   tools/perf/add_copies.sh
#
# Needs: the app open on «كتبي», «قياس السرعة» on (the script knows a book
# was added when the speed log says it was opened), the picker last used in
# that folder. Coordinates are for a 1080x2400 screen.
set -uo pipefail
export MSYS_NO_PATHCONV=1

ADB=${ADB:-/d/dev/android-sdk/platform-tools/adb.exe}
PKG=org.alhikmeh.nots
DIR=/sdcard/Download/اختبار_10GB
WAIT=/sdcard/Download/.10gb_waiting
DONE=/sdcard/Download/.10gb_done
LOG=/sdcard/Android/data/$PKG/files/speed.log

sh() { "$ADB" shell "$@" | tr -d '\r'; }
opened() { sh "grep -c 'open: book' $LOG"; }

sh "mkdir -p $WAIT $DONE; mv $DIR/*.pdf $WAIT/ 2>/dev/null"
files=$(sh "ls $WAIT" | grep -i '\.pdf$' | sort -t_ -k4 -n)
total=$(echo "$files" | grep -c .)
echo "$total files to add"
n=0
start=$(date +%s)
for f in $files; do
  n=$((n + 1))
  sh "mv '$WAIT/$f' $DIR/"
  before=$(opened)
  t0=$(date +%s)
  "$ADB" shell input tap 138 2118   # the star
  sleep 1.5
  "$ADB" shell input tap 540 2090   # «إضافة كتاب»
  sleep 2.5
  # The picker opens in the last folder it was used in. In the folder with
  # the copies a PDF is on the screen; anywhere else (the first time) the
  # folder's own row is the first in «Download».
  sh "uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; grep -c '\.pdf' /sdcard/ui.xml" > /tmp/pdfs.txt
  if [ "$(cat /tmp/pdfs.txt)" = "0" ]; then
    "$ADB" shell input tap 760 840   # the folder
    sleep 2
  fi
  "$ADB" shell input tap 640 840    # the only file
  ok=0
  for _ in $(seq 1 120); do
    sleep 1
    if [ "$(opened)" -gt "$before" ]; then ok=1; break; fi
  done
  sleep 1
  "$ADB" shell input keyevent KEYCODE_BACK   # out of the reader
  sleep 1.5
  sh "mv '$DIR/$f' $DONE/"
  if [ $ok = 1 ]; then
    echo "[$n/$total] $f  $(( $(date +%s) - t0 ))s"
  else
    echo "[$n/$total] $f  NOT ADDED (no book opened in 120 s), stopping"
    break
  fi
done
sh "mv $DONE/*.pdf $DIR/ 2>/dev/null; mv $WAIT/*.pdf $DIR/ 2>/dev/null; rmdir $WAIT $DONE"
echo "done: $n in $(( $(date +%s) - start ))s"
