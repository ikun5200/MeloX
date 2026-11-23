#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DEVICE_NAME="${MELOX_SIM_DEVICE:-iPhone 17}"
UDID="$(
  xcrun simctl list devices available -j |
    python3 -I -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name") == name:
            print(device["udid"])
            raise SystemExit
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            print(device["udid"])
            raise SystemExit
raise SystemExit(1)
' "$DEVICE_NAME"
)"

if [[ -z "${UDID}" ]]; then
  echo "::error::No available iOS simulator found / 没有可用的 iOS 模拟器"
  exit 1
fi

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b

DERIVED_DATA="build/DerivedData-Sim"
xcodebuild \
  -project MeloX.xcodeproj \
  -scheme MeloX \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=${UDID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$(
  find "${DERIVED_DATA}/Build/Products/Debug-iphonesimulator" \
    -maxdepth 2 -name MeloX.app -print -quit
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "::error::Simulator app bundle not found / 未找到模拟器 App"
  exit 1
fi

xcrun simctl install "$UDID" "${APP_PATH}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Info.plist")"
xcrun simctl terminate "$UDID" "${BUNDLE_ID}" >/dev/null 2>&1 || true

LAUNCH_OUTPUT="$(xcrun simctl launch "$UDID" "${BUNDLE_ID}")"
echo "${LAUNCH_OUTPUT}"
PID="$(echo "${LAUNCH_OUTPUT}" | awk '{print $2}')"

sleep 8

if ! kill -0 "${PID}" 2>/dev/null; then
  echo "::error::MeloX exited during launch smoke test / 启动冒烟测试中应用退出"
  exit 1
fi

xcrun simctl io "$UDID" screenshot /tmp/melox-simulator-smoke.png >/dev/null
if [[ ! -s /tmp/melox-simulator-smoke.png ]]; then
  echo "::error::Simulator screenshot was not captured / 未截取到模拟器截图"
  exit 1
fi

echo "Simulator smoke test passed / 模拟器冒烟测试通过 (PID ${PID})"
