#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -derivedDataPath work/build CODE_SIGNING_ALLOWED=NO build
APP="work/build/Build/Products/Debug/薪动日常.app"
for framework in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --deep --sign - "$framework"
done
codesign --force --sign - --entitlements BoringNotchXPCHelper/BoringNotchXPCHelper.entitlements \
  "$APP/Contents/XPCServices/BoringNotchXPCHelper.xpc"
codesign --force --sign - --entitlements boringNotch/boringNotch.entitlements "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built and verified: %s/%s\n' "$PROJECT_ROOT" "$APP"
