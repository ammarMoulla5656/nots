#!/usr/bin/env bash
# A violent, repeatable test of قلم المصدر on the phone, staying inside the
# app: fast flings and tab switching, big books opened one after another,
# every writing tool (pen, highlighter, shapes, laser), undo, tools
# switched as fast as a finger can, page jumps, notes made and written on.
# Coordinates are for a 1080x2400 screen, the app open on «كتبي» with
# «قياس السرعة» on.
#
# It never presses the phone's back key (that leaves the app): the reader's
# own arrow goes back. After every step it checks that the app is still in
# front, and stops at once when it is not.
#
#   tools/perf/stress.sh            # the test only
#   tools/perf/stress.sh measured   # with phone_perf.sh running beside it
#   python tools/perf/summarize.py <run dir>
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "$0")" && pwd)
ADB=${ADB:-/d/dev/android-sdk/platform-tools/adb.exe}
PKG=org.alhikmeh.nots
sh() { "$ADB" shell "$@"; }

chk() { # the app must be in front
  if ! sh "dumpsys activity activities | grep -m1 topResumedActivity" | grep -q "$PKG"; then
    echo "STOPPED: $PKG is not in front ($1)"; exit 1
  fi
}

# Batches run on the phone: no round trip to the PC for each touch.
fling_down() { sh "for i in \$(seq 1 $1); do input swipe 540 1900 540 600 90; done"; }
fling_up() { sh "for i in \$(seq 1 $1); do input swipe 540 600 540 1900 90; done"; }
tabs() { sh "for i in \$(seq 1 $1); do input tap 900 2118; input tap 654 2118; input tap 408 2118; done"; }
strokes() { # $1 strokes down the page
  sh "for i in \$(seq 1 $1); do y=\$((520 + (i * 53) % 1250)); x=\$((120 + (i * 97) % 300)); input swipe \$x \$y \$((x + 520 + (i * 31) % 200)) \$((y + (i * 17) % 90)) 140; done"
}
# The bars go away by themselves 5 s after the last touch (at once when
# writing starts); the round tab at the top brings them back.
wake() { sleep 5.8; sh "input tap 540 150"; sleep 0.8; }
PEN=742; HILITE=622; SHAPES=862; LASER=502; HAND=982; UNDO=120
tool() { wake; sh "input tap $1 342"; sleep 0.4; }
burst() { # tools switched as fast as a finger can: the bars stay in view
  sh "for i in \$(seq 1 $1); do input tap $PEN 342; input tap $HILITE 342; input tap $SHAPES 342; input tap $LASER 342; input tap $HAND 342; done"
}
undo() { sh "for i in \$(seq 1 $1); do input tap $UNDO 342; done"; }
leave_reader() { wake; sh "input tap 984 180"; sleep 2.5; } # the reader's own arrow

use_book_tools() { # inside a reader
  tool $PEN; strokes 40; chk pen
  tool $HILITE; strokes 25; chk highlighter
  tool $SHAPES; strokes 15; chk shapes
  tool $LASER; strokes 15; chk laser
  wake; undo 30; chk undo
  burst 8; chk "tool burst"
  sh "input tap $HAND 342"; sleep 0.3
  fling_down 40; fling_up 20; chk flings
}

STEP=0; T0=$(date +%s)
say() { STEP=$((STEP + 1)); echo "[$STEP] $*  ($(( $(date +%s) - T0 ))s)"; }

chk "start"
if [ "${1:-}" = measured ]; then
  bash "$HERE/phone_perf.sh" 960 stress > /tmp/stress_perf.txt 2>&1 &
  PERF=$!
  sleep 3
fi

say "home: fast flings and tab switching"
fling_up 30; fling_down 25; fling_up 25
tabs 12; chk tabs
fling_down 15; fling_up 15
tabs 12; chk tabs
sh "input tap 900 2118"; sleep 1.5     # the tabs loop ends on «ملاحظاتي»: back to «كتبي»
fling_up 40    # to the top of «كتبي»
chk "before the books"

for book in 1 2 3; do
  case $book in 1) X=288; Y=1160;; 2) X=792; Y=1160;; 3) X=288; Y=1900;; esac
  say "book $book (253 MB): open, write with every tool, undo, tool burst, flings, page jumps"
  before=$(sh "grep -c 'open: book' /sdcard/Android/data/$PKG/files/speed.log" | tr -d '')
  sh "input tap $X $Y"; sleep 4.5; chk "open book $book"
  after=$(sh "grep -c 'open: book' /sdcard/Android/data/$PKG/files/speed.log" | tr -d '')
  [ "$after" -gt "$before" ] || { echo "STOPPED: tapping book $book did not open a book"; exit 1; }
  use_book_tools
  for page in 150 20 200; do
    wake; sh "input tap 540 2162"; sleep 1.2
    sh "input text $page"; sh "input keyevent KEYCODE_ENTER"; sleep 3; chk "page $page"
    fling_down 10
  done
  say "book $book: second round of writing"
  use_book_tools
  leave_reader; chk "back from book $book"
  fling_up 30
done

say "notes: three new papers, each written on"
for n in 1 2 3; do
  sh "input tap 138 2118"; sleep 1.8     # the star
  sh "input tap 540 1876"; sleep 3       # «إنشاء الورقة»
  chk "new note $n"
  use_book_tools
  leave_reader; chk "back from note $n"
done

say "library again: flings and switching"
tabs 15; chk tabs
fling_up 30; fling_down 20; fling_up 20
sh "input tap 654 2118"; sleep 2; fling_down 20; fling_up 20   # the books tab
sh "input tap 408 2118"; sleep 2; fling_down 10; fling_up 10   # notes
sh "input tap 900 2118"; sleep 1; fling_down 30; fling_up 30
chk end
say "done, the app stayed in front all the time"

if [ "${1:-}" = measured ]; then
  echo "waiting for the measurement to end…"
  wait $PERF
  head -16 /tmp/stress_perf.txt
fi
