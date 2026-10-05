#!/bin/sh
# capture-exit-latency.sh — timestamp the exit-hotkey chain on a Batocera box while you exit a game.
#
#   physical pad --(evmapy)--> "evmapy" virtual device (KEY_EXIT) --(hotkeygen)--> "batocera hotkeys" (Alt+F4)
#
# Run it over ssh, THEN launch a game and exit it with hotkey+start (hold it however you normally do).
# It waits for the game's evmapy device to appear, records key events (kernel timestamps, so nothing here
# adds latency) on the pad, evmapy and hotkeygen devices until evmapy's device disappears, then prints one
# merged timeline in milliseconds relative to the first KEY_EXIT press.
#
#   PAD_NAME="Generic X-Box pad"   name of the physical pad in /proc/bus/input/devices (default shown)
#   OUT=/var/tmp/exitcap           where the raw captures go
#   MERGE_ONLY=1                   just merge existing captures in $OUT
PAD_NAME="${PAD_NAME:-Generic X-Box pad}"
OUT="${OUT:-/var/tmp/exitcap}"

find_ev() {   # find_ev "<device name>" -> eventN
    awk -v n="$1" 'BEGIN { RS = ""; FS = "\n" }
        index($0, "Name=\"" n "\"") { for (i = 1; i <= NF; i++) if ($i ~ /Handlers=/) { match($i, /event[0-9]+/); print substr($i, RSTART, RLENGTH); exit } }' \
        /proc/bus/input/devices
}

merge() {
    for f in "$OUT"/pad.log "$OUT"/evmapy.log "$OUT"/hotkeys.log; do
        [ -s "$f" ] || continue
        label=$(basename "$f" .log)
        sed -n 's/^Event: time \([0-9.]*\), type 1 (EV_KEY), code [0-9]* (\([A-Z_0-9a-z]*\)), value \([0-2]\)$/\1 '"$label"' \2 \3/p' "$f"
    done | sort -n | awk '
        { t[NR] = $1; lab[NR] = $2; key[NR] = $3; val[NR] = $4 }
        END {
            for (i = 1; i <= NR; i++) if (lab[i] == "evmapy" && key[i] == "KEY_EXIT" && val[i] == 1) { t0 = t[i]; break }
            if (t0 == "") { print "no KEY_EXIT press seen on the evmapy device - did the exit hotkey fire?"; exit 1 }
            printf "%10s  %-8s %-18s %s\n", "ms vs KEY_EXIT", "device", "key", "value(1=down 0=up 2=repeat)"
            for (i = 1; i <= NR; i++) if (val[i] != 2) printf "%+10.0f    %-8s %-18s %s\n", (t[i] - t0) * 1000, lab[i], key[i], val[i]
        }'
}

if [ -n "$MERGE_ONLY" ]; then merge; exit $?; fi

rm -rf "$OUT"; mkdir -p "$OUT"
command -v evtest >/dev/null || { echo "evtest not found"; exit 1; }

echo "Waiting for a game to start (its 'evmapy' input device to appear)... launch a game now."
i=0; EV_EVMAPY=""
while [ -z "$EV_EVMAPY" ]; do
    EV_EVMAPY=$(find_ev evmapy); [ -n "$EV_EVMAPY" ] && break
    i=$((i + 1)); [ $i -gt 1200 ] && { echo "gave up after 2 minutes"; exit 1; }
    sleep 0.1
done
EV_HK=$(find_ev "batocera hotkeys"); EV_PAD=$(find_ev "$PAD_NAME")
echo "capturing: evmapy=$EV_EVMAPY hotkeys=$EV_HK pad=$EV_PAD  (now exit the game with hotkey+start)"

evtest "/dev/input/$EV_EVMAPY" > "$OUT/evmapy.log" 2>&1 &  P1=$!
[ -n "$EV_HK" ]  && { evtest "/dev/input/$EV_HK"  > "$OUT/hotkeys.log" 2>&1 & P2=$!; }
[ -n "$EV_PAD" ] && { evtest "/dev/input/$EV_PAD" > "$OUT/pad.log"     2>&1 & P3=$!; }

# evmapy's device disappears when the game has been torn down; evtest then exits by itself
wait $P1
sleep 3
# TERM, not INT: background jobs of a non-interactive shell ignore SIGINT (evtest flushes every event, so nothing is lost)
kill -TERM $P2 $P3 2>/dev/null; wait $P2 $P3 2>/dev/null
echo; merge
