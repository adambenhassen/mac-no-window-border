#!/bin/zsh
# End-to-end check of noborder.py against tests/hostapp only. Needs SIP disabled and no other
# noborder daemon running (only one debugger can hold Dock).
set -u
typeset -F SECONDS  # fractional, so short check timeouts are exact
cd "${0:A:h}/.."
out=build/e2e
mkdir -p $out
fail=0

probe() {  # probe <wid>: sets cols and px from the current screen state
    cols=$(./winscan --all | awk -F'\t' -v w=$1 '$1==w {print $(NF-1), $NF}')
    screencapture -x -o -l $1 $out/w.png
    px=$(tests/winpixels $out/w.png)
}

check() {  # check <label> <wid> <want winscan columns> <want winpixels output> [timeout s, default 15]
    local cols px deadline=$((SECONDS + ${5:-15}))
    while true; do
        probe $2
        [[ "$cols" == "$3" && "$px" == "$4" ]] && break
        (( SECONDS >= deadline )) && break
        sleep 0.5
    done
    if [[ "$cols" == "$3" && "$px" == "$4" ]]; then
        echo "PASS $1: $cols $px"
    else
        echo "FAIL $1: got '$cols' '$px', want '$3' '$4'"
        fail=1
    fi
}

tagcount() {  # tagcount <log> <wid>: number of "tagging" log lines that name <wid>
    awk -v w=$2 '$3=="tagging" { for (i = 4; i <= NF; i++) if ($i == w) { n++; break } } END { print n + 0 }' $1
}

decisions() {  # decisions <log> <wid>: the daemon's own change lines naming <wid>, as verbs. A line
               # is "<date> <time> squaring pid 1234: 567 568" (restoring the same shape), so the
               # window numbers start at field 6.
    awk -v w=$2 '($3 == "squaring" || $3 == "restoring") {
        for (i = 6; i <= NF; i++) if ($i == w) { print $3; next }
    }' $1
}

ncount() {  # ncount <verb> <wid> <log>: how many times the daemon changed <wid> that way
    decisions $3 $2 | grep -c "^$1$"
}

checkcount() {  # checkcount <label> <want> <got>
    if [[ "$3" == "$2" ]]; then
        echo "PASS $1: $3"
    else
        echo "FAIL $1: got '$3', want '$2'"
        fail=1
    fi
}

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

native_path() {  # the native engine, driven through the probe, verified on pixels
    typeset out=build/e2e
    [[ -f build/noborder-probe ]] || { echo "FAIL no build/noborder-probe (make probe)"; fail=1; return; }

    windowShot $out/pre.png
    log=$out/native.log
    build/noborder-probe apply $host $max > $log 2>&1
    grep -q "^applying $max" $log && echo "PASS native logs applying: $(head -1 $log)" \
        || echo "FAIL native did not log applying: $(head -3 $log)"
    grep -q "^applying $max" $log || fail=1

    # corners and rim, the same reading the legacy path uses
    probe_px
    [[ "$px" == "square=1 rim=0" ]] && echo "PASS native applied on pixels: $px" \
        || { echo "FAIL native applied on pixels: got '$px', want 'square=1 rim=0'"; fail=1; }
    # Spec finding 3: winscan's shadow column keeps reporting a shadow after the outline is gone. It
    # is printed here to show the native path never consults it: every decision above is pixels.
    echo "note winscan after native apply (not a signal): $(./winscan --all | awk -F'\t' -v w=$max '$1==w {print $(NF-1), $NF}')"

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

# The built app, run for real. `NOBORDER_E2E=app`.
#
# This is the only mode that runs the shipped product: the scan loop, the scanner, the real engine and
# the app's own log file. It is also the only mode that touches the user's other apps — the native
# scan sees every window on the screen, and the legacy one attaches to Dock — so it is run on request,
# not as part of `make test`.
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

    # The native engine, in the app: the same window, the same pixels, judged through the app's log.
    # The app's own lines are timestamped, like the daemon's, so the patterns are not anchored.
    runapp native -noborderEngine native
    if await "applying $max\$"; then
        echo "PASS app(native) logs applying: $(applog | grep "applying $max" | head -1)"
    else
        echo "FAIL app(native) never applied the maximized window: $(applog | tail -5)"
        fail=1
    fi
    probe_px
    [[ "$px" == "square=1 rim=0" ]] && echo "PASS app(native) squares the window: $px" \
        || { echo "FAIL app(native) pixels: got '$px', want 'square=1 rim=0'"; fail=1; }
    windowShot $out/app-applied.png
    band=$(windowBand $out/app-pre.png $out/app-applied.png)
    verdict=$(windowVerdict $band)
    [[ "$verdict" == "changed=1"* ]] && echo "PASS app(native) changed the window's own pixels: $verdict" \
        || { echo "FAIL app(native) left the window's pixels unchanged: $band ($verdict)"; fail=1; }

    kill -USR1 $host
    if await "restoring $max\$"; then
        echo "PASS app(native) logs restoring after un-maximizing: $(applog | grep "restoring $max" | head -1)"
    else
        echo "FAIL app(native) did not restore the un-maximized window: $(applog | tail -5)"
        fail=1
    fi
    probe_px
    [[ "$px" == "square=0 rim=1" ]] && echo "PASS app(native) puts the window back: $px" \
        || { echo "FAIL app(native) after restore: got '$px', want 'square=0 rim=1'"; fail=1; }
    windowShot $out/app-restored.png
    band=$(windowBand $out/app-pre.png $out/app-restored.png)
    verdict=$(windowVerdict $band)
    [[ "$verdict" == *"clean=1"* ]] && echo "PASS app(native) restore returns the original pixels: $band" \
        || { echo "FAIL app(native) restore left the window changed: $band ($verdict)"; fail=1; }
    # The log says every refusal once per process, not once per scan (four a second would bury it).
    local refusals=$(applog | grep -c "skipped (not AppKit)")
    local pids=$(applog | awk '$4=="(not" && $5=="AppKit)" {print $6}' | sort -u | wc -l)
    [[ "$refusals" == "$pids" ]] && echo "PASS app(native) says each refusal once per process: $refusals for $pids processes" \
        || { echo "FAIL app(native) repeats refusals: $refusals lines for $pids processes"; fail=1; }
    stopapp

    # No arguments: the shipped default, which is the native engine now. Asserted by what the app
    # does to a window, not by a log line about its own configuration.
    runapp default
    if await "applying $max\$" 20; then
        echo "PASS app with no arguments runs the native engine: $(applog | grep "applying $max" | head -1)"
    else
        echo "FAIL app with no arguments did not apply the maximized window: $(applog | tail -5)"
        fail=1
    fi
    stopapp

    # The legacy engine, named on the command line: the app must still start the Python daemon, as it
    # did in v1.1. This is what "both engines until the number says otherwise" keeps true.
    runapp legacy -noborderEngine legacy
    if await "^status: running"; then
        echo "PASS app(-noborderEngine legacy) starts the daemon: $(applog | grep "^status: running" | head -1)"
    else
        echo "FAIL app(-noborderEngine legacy) did not start the daemon: $(applog | tail -5)"
        fail=1
    fi
    stopapp
}

host=""
daemon=""
parent=""
daemon2=""
app=""
cleanup() {
    [[ -n $parent ]] && kill -9 $parent 2>/dev/null
    [[ -n $app ]] && kill -TERM $app 2>/dev/null
    for d in $daemon $daemon2; do  # SIGTERM restores; wait up to 30 s before killing the host
        kill -TERM $d 2>/dev/null || continue
        for _ in {1..60}; do kill -0 $d 2>/dev/null || break; sleep 0.5; done
        kill -9 $d 2>/dev/null
    done
    [[ -n $host ]] && kill $host 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if pgrep -f 'noborder.py' >/dev/null; then
    echo "stop the running noborder daemon first"
    exit 2
fi
tests/hostapp > $out/host.txt & host=$!
sleep 1.5
max=$(awk '$1=="max" {print $2}' $out/host.txt)
float=$(awk '$1=="floating" {print $2}' $out/host.txt)

export NOBORDER_GRACE_S=0  # the test app was just launched

if [[ "${NOBORDER_E2E:-}" == app ]]; then   # the built app itself, both engines
    app_mode
    exit $fail
fi

if [[ "${NOBORDER_ENGINE:-}" == native ]]; then   # the native engine: no daemon, the probe drives it
    native_path
    exit $fail
fi

./noborder.py --pids $host > $out/daemon.log 2>&1 & daemon=$!
check "maximized applied" $max "[noshadow] [max]" "square=1 rim=0"
before=$(tagcount $out/daemon.log $max)
sleep 6
after=$(tagcount $out/daemon.log $max)
if (( after == before )); then
    echo "PASS no re-tagging of an applied window: $after tagging lines"
else
    echo "FAIL applied window re-tagged: $before -> $after tagging lines in 6 s"
    fail=1
fi
check "floating untouched" $float "[shadow] [nomax]" "square=0 rim=1"

# The geometry decision, read from the daemon's own log and not from winscan's [max] column: that
# column is the same rule in the C scanner, so asserting it here would only show that two copies of
# the rule agree with each other. These lines are the decision the scan loop makes in the app: the
# window filling a screen's usable area is chosen, the 600x400 one is never mentioned.
checkcount "geometry: the maximized window was applied once" 1 "$(ncount squaring $max $out/daemon.log)"
checkcount "geometry: the floating window was never changed" 0 "$(ncount squaring $float $out/daemon.log)"
checkcount "geometry: the floating window was never restored" 0 "$(ncount restoring $float $out/daemon.log)"

kill -USR1 $host
check "un-maximized restored" $max "[shadow] [nomax]" "square=0 rim=1"
# The window is 600x400 now: the daemon stopped seeing it fill the usable area and restored it. A
# second restore for it would mean the decision is being re-made every scan.
checkcount "geometry: un-maximizing restored it once" 1 "$(ncount restoring $max $out/daemon.log)"
kill -USR2 $host
check "re-maximized applied (warm, within 5 s)" $max "[noshadow] [max]" "square=1 rim=0" 5

kill -TERM $daemon
for _ in {1..60}; do kill -0 $daemon 2>/dev/null || break; sleep 0.5; done
if kill -0 $daemon 2>/dev/null; then
    echo "FAIL daemon did not exit within 30 s; killing"
    kill -9 $daemon
    fail=1
fi
wait $daemon
code=$?
daemon=""  # reaped; never signal its pid again
check "restored on SIGTERM" $max "[shadow] [max]" "square=0 rim=1"
if [[ $code == 0 ]] && grep -q '^status: stopped' $out/daemon.log; then
    echo "PASS clean exit with 'status: stopped'"
else
    echo "FAIL exit code $code or no 'status: stopped' line"
    fail=1
fi

# The app reads the daemon's output through a pipe. When the app dies, the daemon must still
# restore every window although the pipe has no reader.
python3 -c 'import subprocess, sys
p = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(p.pid, flush=True)
for line in p.stdout:
    sys.stdout.buffer.write(line)
    sys.stdout.flush()' ./noborder.py --pids $host > $out/parent.log & parent=$!
for _ in {1..20}; do daemon2=$(head -n 1 $out/parent.log); [[ -n $daemon2 ]] && break; sleep 0.25; done
check "maximized applied under a piped parent" $max "[noshadow] [max]" "square=1 rim=0"
kill -9 $parent
wait $parent 2>/dev/null
killed=$SECONDS
while kill -0 $daemon2 2>/dev/null && (( SECONDS < killed + 15 )); do sleep 0.25; done
if kill -0 $daemon2 2>/dev/null; then
    echo "FAIL daemon did not exit within 15 s of its parent's death"
    fail=1
else
    daemon2=""
    printf "PASS daemon exited %.1f s after its parent's death\n" $((SECONDS - killed))
fi
left=$((killed + 15 - SECONDS))
check "restored after parent death" $max "[shadow] [max]" "square=0 rim=1" $(( left > 1 ? left : 1 ))
exit $fail
