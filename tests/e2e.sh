#!/bin/zsh
# End-to-end check of the engine against tests/hostapp only. Needs SIP disabled.
#
# Two modes, both driving tests/hostapp only:
#   default       build/noborder-probe drives one window and the pixels are checked. Nothing runs the
#                 app, so this is the path `make test` can gate on.
#   NOBORDER_E2E=app
#                 the built app and its real 250 ms scan loop, inside its period. This is the only
#                 mode that runs the shipped product, and the only one that sees the user's other
#                 windows, so it is run on request and needs the user's own NoBorder quit first.
set -u
typeset -F SECONDS  # fractional, so short check timeouts are exact
cd "${0:A:h}/.."
out=build/e2e
mkdir -p $out
fail=0

windowShot() {  # windowShot <png>: the maximized window's own bits, captured by window id.
    # Nothing is drawn in front of a window capture, and no other window's content can appear in it:
    # that is what makes it a reading of *this* window. A screen-region capture is neither — it has
    # shown the user's terminal (clean=1 with the change present) and a scrolled terminal panel
    # (1450 of 1450 rows at both edge columns, the whole strip, which is not a window outline).
    screencapture -x -o -l $max $1
}

windowBand() {  # windowBand <a.png> <b.png>: compare every pixel of the window's own capture
    typeset w=$(sips -g pixelWidth $1 | awk '/pixelWidth/{print $2}')
    tests/pxband $1 $2 $edgeThr 0 $w 0 1
}

windowVerdict() {  # windowVerdict <pxband line>: changed (some of the window's own pixels moved) and
                   # clean (none of them did). Measured over the whole window on purpose: what the
                   # change does, in pixels, is the rim's 1 px line under the titlebar across the
                   # full width and the corner curves down the sides — about 16 rows on a 2250-row
                   # capture. That is the honest size of it, so the assertion is "any of it moved" and
                   # "none of it is left moved", and the reading of *which* of the three changes
                   # landed is winpixels above. Nothing here can be produced by the desktop: a window
                   # capture contains only the window.
    print -r -- "$1" | awk '
    {   h = 0; rows = -1
        for (i = 1; i <= NF; i++) {
            f = $i
            if (f ~ /^height=/)             { sub(/^height=/, "", f); h = f + 0 }
            else if (f ~ /^rows_with_diff=/) { sub(/^rows_with_diff=/, "", f); rows = f + 0 }
        }
        printf "changed=%d clean=%d rows=%d height=%d", (rows > 0), (rows == 0), rows, h
    }'
}

edgeThr=32

native_path() {  # the engine, driven through the probe, verified on pixels
    typeset out=build/e2e
    [[ -f build/noborder-probe ]] || { echo "FAIL no build/noborder-probe (make probe)"; fail=1; return; }

    windowShot $out/pre.png
    log=$out/native.log
    build/noborder-probe apply $host $max > $log 2>&1
    grep -q "^applying $max" $log && echo "PASS native logs applying: $(head -1 $log)" \
        || echo "FAIL native did not log applying: $(head -3 $log)"
    grep -q "^applying $max" $log || fail=1

    # corners and rim, read off the window itself
    probe_px
    [[ "$px" == "square=1 rim=0" ]] && echo "PASS native applied on pixels: $px" \
        || { echo "FAIL native applied on pixels: got '$px', want 'square=1 rim=0'"; fail=1; }

    # The change, in the window's own pixels: not a heuristic about corners, and not anything the
    # desktop in front of it can fake.
    windowShot $out/applied.png
    band=$(windowBand $out/pre.png $out/applied.png)
    verdict=$(windowVerdict $band)
    [[ "$verdict" == "changed=1"* ]] && echo "PASS native changed the window's own pixels: $verdict" \
        || { echo "FAIL native left the window's pixels unchanged: $band ($verdict)"; fail=1; }

    build/noborder-probe restore $host $max > $out/native-restore.log 2>&1
    grep -q "^restoring $max" $out/native-restore.log && echo "PASS native logs restoring: $(head -1 $out/native-restore.log)" \
        || { echo "FAIL native did not log restoring: $(head -3 $out/native-restore.log)"; fail=1; }
    probe_px
    [[ "$px" == "square=0 rim=1" ]] && echo "PASS native restored on pixels: $px" \
        || { echo "FAIL native restored on pixels: got '$px', want 'square=0 rim=1'"; fail=1; }
    windowShot $out/restored.png
    band=$(windowBand $out/pre.png $out/restored.png)
    verdict=$(windowVerdict $band)
    [[ "$verdict" == *"clean=1"* ]] && echo "PASS native restore returns the original pixels: $band" \
        || { echo "FAIL native restore left the window changed: $band ($verdict)"; fail=1; }

    # Review Focus: a target that is not an AppKit app. It has no window to check, so the assertion
    # is that the engine says why it stopped, and that hostapp's window is left as it was.
    tests/plainrunloop > $out/plain.txt & plain=$!
    for _ in {1..20}; do [[ -s $out/plain.txt ]] && break; sleep 0.25; done
    build/noborder-probe apply $plain 4242 > $out/plain.log 2>&1
    grep -q "skipped (not AppKit) $plain" $out/plain.log \
        && echo "PASS native skips a target that is not AppKit: $(head -1 $out/plain.log)" \
        || { echo "FAIL native on a non-AppKit target: $(head -3 $out/plain.log)"; fail=1; }
    kill $plain 2>/dev/null; wait $plain 2>/dev/null
    probe_px
    [[ "$px" == "square=0 rim=1" ]] && echo "PASS non-AppKit target left the window alone: $px" \
        || { echo "FAIL non-AppKit target changed the window: $px"; fail=1; }
}

probe_px() {  # probe_px: sets px from a window capture of the maximized window
    screencapture -x -o -l $max $out/w.png
    px=$(tests/winpixels $out/w.png)
}

float_px() {  # float_px: the same reading of the 600x400 window, which nothing may change
    screencapture -x -o -l $float $out/float.png
    px=$(tests/winpixels $out/float.png)
}

# The built app, run for real. `NOBORDER_E2E=app`.
#
# This is the only mode that runs the shipped product: the scan loop, the scanner, the real engine and
# the app's own log file. It is also the only mode that sees the user's other windows — the scan runs
# over every window on the screen — so it is run on request, not as part of `make test`, and it needs
# the user's own NoBorder quit: two apps would be acting on the same windows.
app_mode() {
    typeset binary=build/NoBorder.app/Contents/MacOS/NoBorder
    typeset logfile=$HOME/Library/Logs/macos-no-window-border.log
    [[ -x $binary ]] || { echo "FAIL no built app: $binary (make app)"; fail=1; return; }
    touch $logfile

    windowShot $out/app-pre.png

    app=""
    applog() {  # only the lines this run wrote
        tail -c +$(( appStart + 1 )) $logfile
    }
    await() {  # await <pattern>: wait for a line in the app's log, up to 40 s
        local deadline=$((SECONDS + ${2:-40}))
        while true; do
            applog | grep -q "$1" && return 0
            (( SECONDS >= deadline )) && return 1
            sleep 0.5
        done
    }
    runapp() {  # runapp <label> <args…>: start the app, remembering where its log starts
        typeset label=$1
        shift
        appStart=$(wc -c < $logfile)
        $binary "$@" > $out/$label.log 2>&1 & app=$!
        echo "note app started for $label (pid $app): $*"
    }
    stopapp() {  # SIGTERM: the app puts every window it changed back, then exits
        [[ -n $app ]] || return
        kill -TERM $app 2>/dev/null
        local deadline=$((SECONDS + 30))
        while kill -0 $app 2>/dev/null && (( SECONDS < deadline )); do sleep 0.25; done
        if kill -0 $app 2>/dev/null; then
            echo "FAIL the app did not exit within 30 s of SIGTERM"
            fail=1
            kill -9 $app 2>/dev/null
        fi
        wait $app 2>/dev/null
        app=""
    }

    # The engine in the app: the same window, the same pixels, judged through the app's log.
    # The app's own lines are timestamped, so the patterns are not anchored.
    runapp app
    if await "applying $max\$"; then
        echo "PASS app logs applying: $(applog | grep "applying $max" | head -1)"
    else
        echo "FAIL app never applied the maximized window: $(applog | tail -5)"
        fail=1
    fi
    probe_px
    [[ "$px" == "square=1 rim=0" ]] && echo "PASS app squares the window: $px" \
        || { echo "FAIL app pixels: got '$px', want 'square=1 rim=0'"; fail=1; }
    windowShot $out/app-applied.png
    band=$(windowBand $out/app-pre.png $out/app-applied.png)
    verdict=$(windowVerdict $band)
    [[ "$verdict" == "changed=1"* ]] && echo "PASS app changed the window's own pixels: $verdict" \
        || { echo "FAIL app left the window's pixels unchanged: $band ($verdict)"; fail=1; }

    kill -USR1 $host
    if await "restoring $max\$"; then
        echo "PASS app logs restoring after un-maximizing: $(applog | grep "restoring $max" | head -1)"
    else
        echo "FAIL app did not restore the un-maximized window: $(applog | tail -5)"
        fail=1
    fi
    probe_px
    [[ "$px" == "square=0 rim=1" ]] && echo "PASS app puts the window back: $px" \
        || { echo "FAIL app after restore: got '$px', want 'square=0 rim=1'"; fail=1; }
    # No pixel-band comparison here, on purpose: un-maximizing resizes the window, so the pre
    # capture (maximized) and this one (its own frame) are not the same picture. The probe path, which
    # leaves the window maximized, is where the band proves the change is fully undone.

    # The log says every refusal once per process, not once per scan (four a second would bury it).
    local refusals=$(applog | grep -c "skipped (not AppKit)")
    local pids=$(applog | awk '$4=="(not" && $5=="AppKit)" {print $6}' | sort -u | wc -l | tr -d ' ')
    [[ "$refusals" == "$pids" ]] && echo "PASS app says each refusal once per process: $refusals for $pids processes" \
        || { echo "FAIL app repeats refusals: $refusals lines for $pids processes"; fail=1; }

    # Never act on a window we did not apply: the 600x400 window is on screen, is not maximized, and
    # the loop scans every window it can see. It must never be named in the log, and none of its
    # pixels may have moved while the loop ran next to it.
    local named=$(applog | grep -cE "(^| )$float( |$)")
    float_px
    [[ "$named" == "0" && "$px" == "square=0 rim=1" ]] \
        && echo "PASS app never touches the floating window: $named lines, $px" \
        || { echo "FAIL app acted on the floating window: $named lines, got '$px'"; fail=1; }
    stopapp
}

host=""
app=""
cleanup() {
    [[ -n $app ]] && kill -TERM $app 2>/dev/null
    [[ -n $host ]] && kill $host 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

tests/hostapp > $out/host.txt & host=$!
sleep 1.5
max=$(awk '$1=="max" {print $2}' $out/host.txt)
float=$(awk '$1=="floating" {print $2}' $out/host.txt)

if [[ "${NOBORDER_E2E:-}" == app ]]; then
    app_mode
else
    native_path
fi
exit $fail
