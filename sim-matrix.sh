#!/bin/bash
# Launch the Droplis simulator build on every available iPhone/iPad of one runtime, ONE AT A TIME,
# under several settings; record whether the app survives 25 s, a screenshot, the app log and any crash report.
# usage: sim-matrix.sh <path/to/Droplis.app> <runtime-substring e.g. "iOS 27"> <outDir> [deviceFilter]
set -u
APP="$1"; RT="$2"; OUT="$3"; FILTER="${4:-.}"
BID=com.franzai.droplis
cap() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
mkdir -p "$OUT"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "import sys,json;r=[x for x in json.load(sys.stdin)['runtimes'] if x['isAvailable'] and x['name'].startswith('$RT')];print(r[-1]['identifier'] if r else '')")
[ -z "$RUNTIME" ] && { echo "no runtime $RT"; xcrun simctl list runtimes; exit 1; }
echo "runtime $RUNTIME" | tee "$OUT/summary.txt"
DEVICES=$(xcrun simctl list devicetypes -j | python3 -c "
import sys,json
for d in json.load(sys.stdin)['devicetypes']:
  n=d['name']
  if (n.startswith('iPhone 1') or n.startswith('iPad')) : print(d['identifier']+'|'+n)" | grep -E "$FILTER")
crashdir="$HOME/Library/Logs/DiagnosticReports"
run_one() { # udid label variant
  local udid=$1 label=$2 variant=$3 tag="$2--$3"
  tag=$(echo "$tag" | tr ' ()' '___')
  local before; before=$(ls "$crashdir" 2>/dev/null | sort)
  xcrun simctl terminate "$udid" $BID >/dev/null 2>&1
  xcrun simctl uninstall "$udid" $BID >/dev/null 2>&1
  cap 120 xcrun simctl install "$udid" "$APP" || { echo "$tag INSTALL_FAILED" | tee -a "$OUT/summary.txt"; return; }
  local args=()
  case $variant in
    dark) xcrun simctl ui "$udid" appearance dark ;;
    light) xcrun simctl ui "$udid" appearance light ;;
    bigtext) xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large ;;
    german) args=(-AppleLanguages "(de)" -AppleLocale de_AT) ;;
    japanese) args=(-AppleLanguages "(ja)" -AppleLocale ja_JP) ;;
    relaunch) ;;
  esac
  local start; start=$(date -u +"%Y-%m-%d %H:%M:%S")
  xcrun simctl launch "$udid" $BID ${args[@]+"${args[@]}"} > "$OUT/$tag.launch.txt" 2>&1
  if [ "$variant" = relaunch ]; then sleep 8; xcrun simctl terminate "$udid" $BID; sleep 2; xcrun simctl launch "$udid" $BID >> "$OUT/$tag.launch.txt" 2>&1; fi
  sleep 25
  local alive=DEAD
  xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BID" && alive=ALIVE
  cap 60 xcrun simctl io "$udid" screenshot "$OUT/$tag.png" >/dev/null 2>&1
  cap 90 xcrun simctl spawn "$udid" log show --start "$start" --style compact --predicate "process == \"Droplis\" OR subsystem == \"$BID\" OR (process == \"SpringBoard\" AND eventMessage CONTAINS \"$BID\") OR eventMessage CONTAINS[c] \"Droplis\"" > "$OUT/$tag.log.txt" 2>&1
  local new; new=$(comm -13 <(echo "$before") <(ls "$crashdir" 2>/dev/null | sort) | grep -iE "droplis|webcontent|WebKit" )
  for f in $new; do cp "$crashdir/$f" "$OUT/$tag.$f"; done
  local web; web=$(grep -c "\[droplis\] ready" "$OUT/$tag.log.txt")
  echo "$tag $alive ready=$web crashes=$(echo $new | wc -w | tr -d ' ')" | tee -a "$OUT/summary.txt"
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1
  xcrun simctl ui "$udid" content_size large >/dev/null 2>&1
}
IFS=$'\n'
for line in $DEVICES; do
  type=${line%%|*}; name=${line#*|}
  udid=$(xcrun simctl create "repro $name" "$type" "$RUNTIME" 2>/dev/null) || { echo "$name CREATE_FAILED" >> "$OUT/summary.txt"; continue; }
  echo "== booting $name $udid"; cap 240 xcrun simctl boot "$udid"; cap 300 xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1; echo "== booted $name"
  for v in fresh dark bigtext german relaunch; do run_one "$udid" "$name" "$v"; done
  xcrun simctl shutdown "$udid"; xcrun simctl delete "$udid"
done
echo DONE | tee -a "$OUT/summary.txt"
