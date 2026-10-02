#!/usr/bin/env bash
# driver.sh — build, launch and drive a NucleantUI app on macOS: any
# Examples/<Name> package, or the package's own NucleantUIDemo.
#
#   driver.sh list                     apps it can launch
#   driver.sh launch <App>             build (debug), start in the background, wait for its window
#   driver.sh ss [name]                screenshot the window -> .build/run/shots/<name>.png
#   driver.sh click <x> <y> [count]    click at a window point (title bar included)
#   driver.sh drag <x0> <y0> <x1> <y1> press, move, release
#   driver.sh scroll <x> <y> <dy>      scroll wheel at a window point (dy < 0 scrolls content up)
#   driver.sh key <keycode> [cmd,shift,alt,ctrl]
#   driver.sh type <text>
#   driver.sh window                   "id pid x y w h" of the window, in global points
#   driver.sh release                  let go of every modifier key, system-wide
#   driver.sh quit
#
# Points are window points: screenshot pixels divided by the scale `ss`
# prints. Every input command raises the app first and waits $SETTLE
# seconds (default 0.5) afterwards so the next frame is drawn.

set -euo pipefail

SKILL="$(cd "$(dirname "$0")" && pwd)"
UNIT="$(cd "$SKILL/../../.." && pwd)"
OUT="${RUN_OUT:-$UNIT/.build/run}"
mkdir -p "$OUT/shots"
GUI="$OUT/gui"

gui() {
    if [ ! -x "$GUI" ] || [ "$SKILL/gui.swift" -nt "$GUI" ]; then
        swiftc -O "$SKILL/gui.swift" -o "$GUI" >&2
    fi
    "$GUI" "$@"
}

current() {
    cat "$OUT/current" 2>/dev/null || { echo "nothing launched — driver.sh launch <App>" >&2; exit 1; }
}

package_dir() {
    if [ "$1" = NucleantUIDemo ]; then
        echo "$UNIT"
    elif [ -f "$UNIT/Examples/$1/Package.swift" ]; then
        echo "$UNIT/Examples/$1"
    else
        echo "no app named $1 — driver.sh list" >&2
        exit 1
    fi
}

command="${1:-}"
[ $# -gt 0 ] && shift

case "$command" in
list)
    for dir in "$UNIT"/Examples/*/; do
        [ -f "$dir/Package.swift" ] && basename "$dir"
    done
    echo NucleantUIDemo
    ;;
launch)
    app="${1:?usage: driver.sh launch <App>}"
    dir="$(package_dir "$app")"
    (cd "$dir" && swift build --product "$app" 2>&1 | grep -E "error:|complete!" | tail -8)
    pkill -x "$app" 2>/dev/null && sleep 0.5 || true
    nohup "$dir/.build/debug/$app" >"$OUT/$app.log" 2>&1 &
    echo "$app" >"$OUT/current"
    for _ in $(seq 1 80); do
        gui window "$app" >/dev/null 2>&1 && break
        sleep 0.25
    done
    gui window "$app" >/dev/null || { echo "no window after 20 s — see $OUT/$app.log" >&2; exit 1; }
    # The window is up before the Vulkan swapchain has drawn into it.
    sleep 1.5
    echo "window $(gui window "$app")   log $OUT/$app.log"
    ;;
window)
    app="$(current)"
    gui window "$app"
    ;;
release)
    gui release
    ;;
ss)
    app="$(current)"
    read -r id _ _ _ w h <<<"$(gui window "$app")"
    file="$OUT/shots/${1:-shot}.png"
    screencapture -x -o -l "$id" "$file"
    pixels="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')"
    echo "$file   ${w}x${h} pt   scale $((pixels / w))"
    ;;
click | drag | scroll | key | type)
    app="$(current)"
    gui "$command" "$app" "$@"
    sleep "${SETTLE:-0.5}"
    ;;
quit)
    app="$(current)"
    pkill -x "$app" || true
    rm -f "$OUT/current"
    ;;
*)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
