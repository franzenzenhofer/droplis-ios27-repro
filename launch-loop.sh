#!/bin/bash
# Fresh-install + launch the app N times on ONE simulator, 15 s each; count and keep every new crash report
# of the app's processes (app, WebKit GPU/WebContent/Networking). usage: launch-loop.sh <app> <runtime> <deviceName> <N> <outDir>
set -u
APP="$1"; RT="$2"; DEV="$3"; N="$4"; OUT="$5"; BID=com.franzai.droplis
cap() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
mkdir -p "$OUT"; CR="$HOME/Library/Logs/DiagnosticReports"; mkdir -p "$CR"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "import sys,json;r=[x for x in json.load(sys.stdin)['runtimes'] if x['isAvailable'] and x['name'].startswith('$RT')];print(r[-1]['identifier'])")
TYPE=$(xcrun simctl list devicetypes -j | python3 -c "import sys,json;print([d['identifier'] for d in json.load(sys.stdin)['devicetypes'] if d['name']=='$DEV'][0])")
U=$(xcrun simctl create "loop $DEV" "$TYPE" "$RUNTIME"); cap 240 xcrun simctl boot "$U"; cap 300 xcrun simctl bootstatus "$U" -b >/dev/null 2>&1
before=$(ls "$CR" | sort); dead=0
for i in $(seq 1 "$N"); do
  xcrun simctl terminate "$U" $BID >/dev/null 2>&1; xcrun simctl uninstall "$U" $BID >/dev/null 2>&1
  cap 120 xcrun simctl install "$U" "$APP"; cap 60 xcrun simctl launch "$U" $BID >/dev/null 2>&1
  sleep 15
  xcrun simctl spawn "$U" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BID" || { dead=$((dead+1)); echo "launch $i: APP DEAD"; }
done
new=$(comm -13 <(echo "$before") <(ls "$CR" | sort))
for f in $new; do cp "$CR/$f" "$OUT/"; done
gpu=$(echo "$new" | grep -c "WebKit.GPU"); wc=$(echo "$new" | grep -c "WebContent"); app=$(echo "$new" | grep -ci "droplis")
echo "$DEV $RT launches=$N appDead=$dead gpuCrashes=$gpu webContentCrashes=$wc appCrashes=$app" | tee "$OUT/result.txt"
xcrun simctl shutdown "$U"; xcrun simctl delete "$U"
