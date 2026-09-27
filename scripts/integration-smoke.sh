#!/bin/zsh
# integration-smoke.sh — end-to-end MacHUD check against an ISOLATED MacHUD instance and
# dev builds of Sift, MechaHUD and Wormhole. Never talks to the live instance.
#
#   scripts/integration-smoke.sh            run it (prints each command and a trimmed reply)
#
# Environment (defaults in brackets):
#   MACHUD_BIN        MacHUD binary [<repo>/build/MacHUD.app/Contents/MacOS/MacHUD; ./build.sh debug]
#   MACHUD_SOCKET     isolated control socket [/tmp/machud-test-int.sock]
#   TEST_DIR          isolated config dir [/tmp/machud-test-int]
#   SIFT_BUILD        dir holding Sift.app [~/dev/sift/build]
#   MECHAHUD_BUILD    dir holding MechaHUD.app [~/dev/mechahud/build]
#   WORMHOLE_BUILD    dir holding wormhole.app [~/dev/worktrees/_dd-wormhole/Build/Products/Debug]
#   KEEP_RUNNING=1    leave the instance and the apps up at the end
#
# Siblings that are already running (your own copies) are used as they are and not quit.
set -euo pipefail

repo="${${(%):-%x}:A:h:h}"
MACHUD_BIN="${MACHUD_BIN:-$repo/build/MacHUD.app/Contents/MacOS/MacHUD}"
export MACHUD_SOCKET="${MACHUD_SOCKET:-/tmp/machud-test-int.sock}"
TEST_DIR="${TEST_DIR:-/tmp/machud-test-int}"
export MACHUD_CONFIG="$TEST_DIR/layouts.json"
export MACHUD_NO_HOTKEYS=1
SIFT_BUILD="${SIFT_BUILD:-$HOME/dev/sift/build}"
MECHAHUD_BUILD="${MECHAHUD_BUILD:-$HOME/dev/mechahud/build}"
WORMHOLE_BUILD="${WORMHOLE_BUILD:-$HOME/dev/worktrees/_dd-wormhole/Build/Products/Debug}"

SIFT=xyz.machud.sift
MECHA=xyz.machud.mechahud
WORM=JER.wormhole

for live in "/tmp/machud-$(id -u).sock"; do
  if [[ "$MACHUD_SOCKET" == "$live" ]]; then
    echo "refusing: MACHUD_SOCKET is the live instance's socket" >&2; exit 2
  fi
done
[[ -x "$MACHUD_BIN" ]] || { echo "no MacHUD binary at $MACHUD_BIN (run ./build.sh debug)" >&2; exit 2; }
for d in "$SIFT_BUILD/Sift.app" "$MECHAHUD_BUILD/MechaHUD.app" "$WORMHOLE_BUILD/wormhole.app"; do
  [[ -d "$d" ]] || { echo "missing $d" >&2; exit 2; }
done

gs() { "$MACHUD_BIN" ctl "$@"; }
# step <jq filter> <command args...>: print the command, then the trimmed reply.
step() {
  local filter="$1"; shift
  print -r -- "\$ machud $*"
  gs "$@" | jq -c "$filter"
  print
}
running() { pgrep -f "$1" >/dev/null 2>&1; }

# Apps that were already up belong to the user: leave them alone at the end.
typeset -A preexisting
running "Sift.app/Contents/MacOS" && preexisting[$SIFT]=1 || true
running "MechaHUD.app/Contents/MacOS" && preexisting[$MECHA]=1 || true
running "wormhole.app/Contents/MacOS" && preexisting[$WORM]=1 || true

mkdir -p "$TEST_DIR"
cat > "$MACHUD_CONFIG" <<EOF
{
  "gap": 0,
  "layouts": [{"name": "MacHUD", "regions": [
    {"id": "left", "name": "Left", "x": 0, "y": 0, "w": 0.5, "h": 1},
    {"id": "right", "name": "Right", "x": 0.6, "y": 0.35, "w": 0.4, "h": 0.4},
    {"id": "strip", "name": "Strip", "x": 0, "y": 0.3, "w": 0.3, "h": 0.4}]}],
  "loadouts": [{"name": "Ecosystem", "layout": "MacHUD", "slots": [
    {"regionID": "left", "occupant": {"kind": "panel", "id": "$SIFT/browser"}},
    {"regionID": "right", "occupant": {"kind": "panel", "id": "$WORM/portal"}, "mode": "parked", "edge": "right"},
    {"regionID": "strip", "occupant": {"kind": "panel", "id": "$MECHA/dashboard"}, "mode": "parked", "edge": "left"}]}],
  "apps": {
    "searchPaths": ["$SIFT_BUILD", "$MECHAHUD_BUILD", "$WORMHOLE_BUILD"],
    "standardDirectories": false,
    "$MECHA": {"placement": {"mode": "parked", "edge": "left"}}
  }
}
EOF

pid=""
cleanup() {
  [[ "${KEEP_RUNNING:-0}" == 1 ]] && return
  for id in $SIFT $WORM $MECHA; do
    [[ -n "${preexisting[$id]:-}" ]] && continue
    gs apps quit id=$id >/dev/null 2>&1 || true
  done
  sleep 1
  gs quit >/dev/null 2>&1 || true
  [[ -n "$pid" ]] && { sleep 1; kill "$pid" 2>/dev/null || true; }
}
trap cleanup EXIT

if ! gs ping >/dev/null 2>&1; then
  "$MACHUD_BIN" >"$TEST_DIR/machud.log" 2>&1 &
  pid=$!
  for _ in {1..50}; do gs ping >/dev/null 2>&1 && break; sleep 0.2; done
fi

apps_filter='{ok, apps: [.apps[] | {id, health, placement, placementResult} | with_entries(select(.value != null))]}'

step "$apps_filter" apps
# Default placement: MechaHUD is configured to park on the left when MacHUD launches it.
step '{ok, placement, health: .app.health}' apps launch id=$MECHA
sleep 3
step "$apps_filter | .apps |= map(select(.id == \"$MECHA\"))" apps
step '{ok, parked: [.parked[] | {id, label, kind, edge}]}' park list

for p in $SIFT/browser $WORM/portal $MECHA/dashboard; do
  step '{ok, visible, mode}' panel show id=$p
done
sleep 4
step '{ok, panels: [.panels[] | select(.app != null) | {id, health, cooperative, visible, mode}]}' panels

step '{ok, placed, failed}' apply loadout=Ecosystem
sleep 1
# Where the windows ended up (Cocoa coordinates): Sift fills the left half; the parked
# ones sit past their edges.
step '{ok, panels: [.panels[] | select(.app != null) | {id, mode, frame: .frames[0]}]}' panels
step '{ok, parked: [.parked[] | {id, label, kind, edge, rest}], orbs: [.orbs[] | {edge, count}]}' park list
step '{ok, panels: [.panels[] | select(.app != null) | {id, visible, mode, frame: .frames[0]}]}' panels

step '{ok, revealed}' park reveal edge=right pin=1
sleep 1
step '{ok, panels: [.panels[] | select(.id == "'$WORM'/portal") | {id, visible, mode, frame: .frames[0]}]}' panels
step '{ok, concealed}' park conceal edge=right
sleep 1
step '{ok, panels: [.panels[] | select(.id == "'$WORM'/portal") | {id, mode, frame: .frames[0]}]}' panels

step '{ok, visible, tabs: [.tabs[] | {id, status, schema, keys: [.sections[].rows[].key]}]}' settings-window show activate=0
step '{ok, value}' settings get key=trigger
step '{ok, sift: [.tabs[] | select(.id == "'$SIFT'") | .sections[].rows[] | {key, control, value}]}' settings-window state
step '{ok, visible}' settings-window hide

# Tool dock: one list (hover apps, then windowed), an L in a corner, and a HUD loadout
# that puts the dock and the siblings' panels back. The isolated instance publishes to
# $TEST_DIR/docks.json, not the shared MacHUD docks.json.
step '{ok, position, buttons: [.buttons[] | {title, group, kind, acceptsDrop}]}' tooldock
step '{ok, position, arms: (.segments | length), buttons: [.buttons[] | {title, edge}]}' tooldock position position=topLeft
step '{ok, dock: .loadout.hud.dock, apps: [.loadout.hud.apps | to_entries[] | {id: .key, panels: .value.panels}]}' capture name=HUD hud=only
step '{ok, position}' tooldock position position=bottom
step '{ok, hud}' apply loadout=HUD
step '{ok, position}' tooldock
jq -c 'keys' "$TEST_DIR/docks.json"

for id in $SIFT $WORM $MECHA; do
  if [[ -n "${preexisting[$id]:-}" ]]; then echo "# $id was already running; not quitting it"; continue; fi
  step '{ok, id, wasRunning}' apps quit id=$id
done
sleep 2
step "$apps_filter" apps
step '{ok, parked: [.parked[].id], orbs: [.orbs[].edge]}' park list
