#!/bin/zsh
# hud-workspace.sh — run one command across the MacHUD family listed in workspace.json,
# then the repos in workspace.local.json beside it when there is one (same format, gitignored:
# checkouts of your own that are not public).
#
#   scripts/hud-workspace.sh clone     clone every repo that is missing (skips OWNER placeholders)
#   scripts/hud-workspace.sh status    git status -sb for each
#   scripts/hud-workspace.sh build     SwiftPM app: ./build.sh; library: swift build;
#                                      Xcode: print the xcodebuild command (not run)
#   scripts/hud-workspace.sh test      swift test for each SwiftPM repo
#   scripts/hud-workspace.sh install   each SwiftPM app's ./install.sh (replaces the installed apps)
#   scripts/hud-workspace.sh clean     delete each SwiftPM repo's .build
#
# Options: --only name[,name...]  limit to those repos.
# Both files are read and checked before anything runs (exit 2 when one is broken); a local
# repo named like a public one is skipped with a note. Paths in each file are relative to that
# file. Missing checkouts are skipped with a note. Exits non-zero when any repo's command failed.
set -uo pipefail

root="${${(%):-%x}:A:h:h}"
manifest="${HUD_WORKSPACE:-$root/workspace.json}"

usage() { sed -n '2,17p' "${${(%):-%x}:A}" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 2; }
shift
only=""
while (( $# )); do
  case "$1" in
    --only) only="${2:-}"; shift 2 ;;
    --only=*) only="${1#--only=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "hud-workspace: unknown argument '$1'"; exit 2 ;;
  esac
done
case "$cmd" in
  clone|status|build|test|install|clean) ;;
  -h|--help|help) usage; exit 0 ;;
  *) print -u2 "hud-workspace: unknown command '$cmd'"; usage >&2; exit 2 ;;
esac
[[ -f "$manifest" ]] || { print -u2 "hud-workspace: no $manifest"; exit 2; }
typeset -a manifests=("$manifest")
local_manifest="${manifest:A:h}/workspace.local.json"
[[ -f "$local_manifest" ]] && manifests+=("$local_manifest")

# field <index> <key>: a string from repos[index] of the current manifest, empty when absent.
field() { plutil -extract "repos.$1.$2" raw -o - "$m" 2>/dev/null || true; }

# Read and check every manifest before running anything, so a broken workspace.local.json
# stops the run up front. A repo is run once, from the first file that names it.
typeset -a entries
typeset -A seen
for m in $manifests; do
  if [[ "$(plutil -type repos "$m" 2>/dev/null)" != array ]]; then
    print -u2 "hud-workspace: $m is not a workspace file: it needs valid JSON with a \"repos\" array"; exit 2
  fi
  count="$(plutil -extract repos raw -o - "$m")"
  for (( i = 0; i < count; i++ )); do
    name="$(field $i name)"
    [[ -n "$name" ]] || { print -u2 "hud-workspace: $m: repos[$i] has no name"; exit 2; }
    if [[ -n "${seen[$name]:-}" ]]; then
      print "note: $name in ${m:t} is already listed in ${seen[$name]:t}; skipping the ${m:t} entry"
      continue
    fi
    seen[$name]="$m"
    entries+=("$m:$i")
  done
done

typeset -a failed skipped ok

# run <name> <dir> <command...>: run in dir, record the outcome.
run() {
  local name="$1" dir="$2"; shift 2
  print -r -- "\$ (cd ${dir/#$HOME/~} && $*)"
  if (cd "$dir" && "$@"); then ok+=("$name"); else failed+=("$name"); fi
}

for entry in $entries; do
  m="${entry%:*}"; i="${entry##*:}"; base="${m:A:h}"
  name="$(field $i name)"; rpath="$(field $i path)"; kind="$(field $i kind)"; git="$(field $i git)"
  [[ -n "$only" && ",$only," != *",$name,"* ]] && continue
  dir="${rpath:-../$name}"; [[ "$dir" == /* ]] || dir="$base/$dir"; dir="${dir:a}"
  print -P "%B== $name%b ($kind, ${dir/#$HOME/~})"

  if [[ "$cmd" == clone ]]; then
    if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then print "   present"; ok+=("$name"); continue; fi
    if [[ -z "$git" || "$git" == *OWNER* ]]; then
      print "   skipped: no git url (replace OWNER in ${m:t})"; skipped+=("$name"); continue
    fi
    run "$name" "${dir:h}" git clone "$git" "${dir:t}"
    continue
  fi

  if [[ ! -d "$dir" ]]; then print "   skipped: not checked out (run clone)"; skipped+=("$name"); continue; fi

  case "$cmd:$kind" in
    status:*)
      run "$name" "$dir" git status -sb ;;
    build:swiftpm-app)
      run "$name" "$dir" ./build.sh ;;
    build:swiftpm-library)
      run "$name" "$dir" swift build ;;
    build:xcode)
      project="$(field $i project)"; scheme="$(field $i scheme)"
      print -r -- "   Xcode project, not built here. Run:"
      print -r -- "   xcodebuild -project ${dir/#$HOME/~}/$project -scheme $scheme -configuration Debug -destination 'platform=macOS' build"
      skipped+=("$name") ;;
    test:swiftpm-*)
      run "$name" "$dir" swift test ;;
    install:swiftpm-app)
      if [[ -x "$dir/install.sh" ]]; then run "$name" "$dir" ./install.sh
      else print "   skipped: no install.sh"; skipped+=("$name"); fi ;;
    clean:swiftpm-*)
      if [[ -d "$dir/.build" ]]; then run "$name" "$dir" rm -rf .build
      else print "   nothing to clean"; ok+=("$name"); fi ;;
    *)
      print "   skipped: '$cmd' does not apply to a $kind repo"; skipped+=("$name") ;;
  esac
done

print
print -P "%B$cmd%b: ${#ok} ok${ok:+ (${(j:, :)ok})}, ${#failed} failed${failed:+ (${(j:, :)failed})}, ${#skipped} skipped${skipped:+ (${(j:, :)skipped})}"
(( ${#failed} == 0 ))
