#!/bin/bash
# Simulator rig for exercising playback against a controllable source.
#
#   rig.sh up [--no-build]  fixtures, HTTPS server, CA trust, build, install
#   rig.sh seed             install the test source and skip first-run prompts
#   rig.sh launch           (re)start the app, logging inside the simulator
#   rig.sh do <cmd> [s]     send a debug command, wait, print the app state
#   rig.sh behave <json>    set what the source answers (see server.py)
#   rig.sh ui <steps>       real touches through XCUITest (see UIRig/UIRigTests)
#   rig.sh shot <name>      screenshot to $RIG/<name>.png
#   rig.sh log [n]          the app's last console lines
#   rig.sh alive            whether the launched process still runs
#   rig.sh crashes          crash reports written since `launch`
#   rig.sh down             stop the server
#
# Commands are listed in MeloX/App/DebugAutomation.swift. The source answers
# from a local server with generated audio; no real source is involved.
# Nothing here is used by device or Release builds.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RIG="${MELOX_RIG_DIR:-/tmp/melox-rig}"
PORT="${MELOX_RIG_PORT:-8443}"
DEVICE_NAME="${MELOX_SIM_DEVICE:-iPhone 17}"
DERIVED="${MELOX_RIG_DERIVED:-$ROOT/build/DerivedData-Sim}"
BUNDLE_ID="azki.moye.MeloX"
QUALITYS="${MELOX_RIG_QUALITYS:-[\"128k\",\"320k\",\"flac\",\"flac24bit\",\"hires\",\"atmos\",\"atmos_plus\",\"master\"]}"

udid() {
  xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
devices = [d for r, ds in json.load(sys.stdin)["devices"].items() if "iOS" in r for d in ds]
match = [d for d in devices if d["name"] == name] or [d for d in devices if "iPhone" in d["name"]]
print(match[0]["udid"] if match else "")' "$DEVICE_NAME"
}

container() { xcrun simctl get_app_container "$(udid)" "$BUNDLE_ID" data; }

# simctl resolves --stdout/--stderr paths inside the device's own filesystem.
simroot() { echo "$HOME/Library/Developer/CoreSimulator/Devices/$(udid)/data"; }

send() {
  local directory; directory="$(container)/Documents"
  rm -f "$directory/debug-state.json"
  printf '%s' "$1" > "$directory/debug-command.txt"
  for _ in $(seq 1 40); do
    [[ -f "$directory/debug-state.json" ]] && return 0
    sleep 0.1
  done
  echo "no response to '$1' (is the app running?)" >&2
  return 1
}

case "${1:-}" in
  up)
    bash "$HERE/make_fixtures.sh" "$RIG" >/dev/null
    U="$(udid)"
    xcrun simctl boot "$U" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$U" -b >/dev/null
    xcrun simctl keychain "$U" add-root-cert "$RIG/ca.pem"
    if ! curl -s --cacert "$RIG/ca.pem" "https://localhost:$PORT/" >/dev/null 2>&1; then
      nohup python3 -I "$HERE/server.py" "$RIG" "$PORT" > "$RIG/server.log" 2>&1 &
      echo $! > "$RIG/server.pid"
      sleep 1
    fi
    [[ -f "$RIG/behaviours.json" ]] || echo '{}' > "$RIG/behaviours.json"
    if [[ "${2:-}" != "--no-build" ]]; then
      (cd "$ROOT" && xcodebuild -project MeloX.xcodeproj -scheme MeloX \
        -configuration Debug -destination "id=$U" \
        -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build) \
        > "$RIG/build.log" 2>&1 || { grep -E "error:" "$RIG/build.log" | sort -u | head -20; exit 1; }
    fi
    xcrun simctl install "$U" "$DERIVED/Build/Products/Debug-iphonesimulator/MeloX.app"
    echo "rig up: $U"
    ;;
  seed)
    U="$(udid)"
    xcrun simctl terminate "$U" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$U" "$BUNDLE_ID" >/dev/null   # creates the container
    sleep 2
    xcrun simctl terminate "$U" "$BUNDLE_ID" >/dev/null 2>&1 || true
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$DERIVED/Build/Products/Debug-iphonesimulator/MeloX.app/Info.plist")"
    for pair in "melox.hasCompletedOnboarding -bool YES" \
                "appReleaseNotes.lastPresentedVersion -string $VERSION" \
                "appRecommendation.hasPresentedPrompt -bool YES" \
                "checksUpdatesOnLaunch -bool NO"; do
      # shellcheck disable=SC2086
      xcrun simctl spawn "$U" defaults write "$BUNDLE_ID" $pair
    done
    python3 -I - "$HERE/test_source.js" "$(container)" "https://localhost:$PORT" "$QUALITYS" <<'EOF'
import json, os, sys, uuid, datetime
script_path, container, backend, qualitys = sys.argv[1:5]
script = open(script_path, encoding="utf-8").read()
script = script.replace("__BACKEND__", backend).replace("__QUALITYS__", qualitys)
source = {
    "id": str(uuid.uuid4()).upper(),
    "name": "MeloX 测试音源",
    "rawScript": script,
    "version": "1.0.0",
    "author": "MeloX",
    "homepage": "",
    "capabilities": [{
        "id": "tx", "name": "QQ", "type": "music",
        "actions": ["musicUrl"], "qualitys": json.loads(qualitys),
    }],
    "isEnabled": True,
    "priority": 0,
    "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
directory = os.path.join(container, "Library", "Application Support", "MeloX")
os.makedirs(directory, exist_ok=True)
with open(os.path.join(directory, "LXSources.json"), "w", encoding="utf-8") as f:
    json.dump([source], f, ensure_ascii=False, indent=2)
print("seeded", os.path.join(directory, "LXSources.json"))
EOF
    ;;
  launch)
    U="$(udid)"
    xcrun simctl terminate "$U" "$BUNDLE_ID" >/dev/null 2>&1 || true
    date +%s > "$RIG/launched-at"
    : > "$RIG/requests.log"
    mkdir -p "$(simroot)/tmp"
    : > "$(simroot)/tmp/melox-app.log"
    xcrun simctl launch --stdout=/tmp/melox-app.log --stderr=/tmp/melox-app.log \
      "$U" "$BUNDLE_ID" | tee "$RIG/launch.out"
    ;;
  log)
    tail -n "${2:-30}" "$(simroot)/tmp/melox-app.log"
    ;;
  do)
    COMMAND="${2:?command}"
    # Test songs report the fixtures' real sizes, as QQ reports a song's.
    [[ "$COMMAND" == play\?* ]] && COMMAND="$COMMAND&sizes=https://localhost:$PORT/sizes"
    send "$COMMAND"
    sleep "${3:-1}"
    send state
    python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
print("  ".join(f"{k}={s[k]}" for k in ("song", "isPlaying", "isLoading", "progress", "playing", "requested", "switching")))
print("  offered=" + ",".join(s["offered"]))
if s["issue"]: print("  ISSUE: " + s["issue"])
if s["notice"]: print("  notice: " + s["notice"])' "$(container)/Documents/debug-state.json"
    ;;
  behave)
    echo "${2:?json}" > "$RIG/behaviours.json"
    ;;
  shot)
    xcrun simctl io "$(udid)" screenshot "$RIG/${2:?name}.png" >/dev/null 2>&1
    sips -Z 760 "$RIG/$2.png" >/dev/null
    echo "$RIG/$2.png"
    ;;
  ui)
    U="$(udid)"
    UI_DERIVED="${MELOX_RIG_UI_DERIVED:-/tmp/melox-uirig-dd}"
    if [[ ! -d "$UI_DERIVED/Build/Products/Debug-iphonesimulator/UIRig-Runner.app" ]]; then
      xcodebuild build-for-testing -project "$HERE/UIRig/UIRig.xcodeproj" -scheme UIRig \
        -destination "id=$U" -derivedDataPath "$UI_DERIVED" > "$RIG/ui-build.log" 2>&1 \
        || { grep -E "error:" "$RIG/ui-build.log" | sort -u | head -20; exit 1; }
    fi
    TEST_RUNNER_RIG_STEPS="${2:?steps}" TEST_RUNNER_RIG_OUT="$RIG" \
    TEST_RUNNER_RIG_BUNDLE="$BUNDLE_ID" \
      xcodebuild test-without-building -project "$HERE/UIRig/UIRig.xcodeproj" -scheme UIRig \
        -destination "id=$U" -derivedDataPath "$UI_DERIVED" > "$RIG/ui.log" 2>&1 \
      || { grep -E "error:|no hittable element" "$RIG/ui.log" | sort -u | head -6; exit 1; }
    ;;
  alive)
    PID="$(awk '{print $2}' "$RIG/launch.out")"
    if kill -0 "$PID" 2>/dev/null; then echo "app alive (pid $PID)"; else echo "APP NOT RUNNING (pid $PID)"; fi
    ;;
  crashes)
    SINCE="$(cat "$RIG/launched-at" 2>/dev/null || echo 0)"
    find "$HOME/Library/Logs/DiagnosticReports" -name "MeloX*" -newermt "@$SINCE" 2>/dev/null \
      || find "$HOME/Library/Logs/DiagnosticReports" -name "MeloX*" -mmin -30
    ;;
  down)
    [[ -f "$RIG/server.pid" ]] && kill "$(cat "$RIG/server.pid")" 2>/dev/null || true
    ;;
  *)
    sed -n '2,18p' "${BASH_SOURCE[0]}"
    exit 2
    ;;
esac
