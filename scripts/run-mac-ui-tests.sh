#!/bin/sh
# Mac UI tests (CommsMacUITests): Comms.app (Debug) in demo mode, screenshots to
# design/refs/live/mac-*.png and the .xcresult.
#
# Signed "to run locally" (ad hoc): no certificates or keychains involved. Xcode gives the
# UI-test runner a `com.apple.application-identifier` entitlement, which an ad hoc signature
# cannot carry on macOS (the runner is killed before it connects), so the runner is re-signed
# ad hoc without it between build-for-testing and test-without-building.
#
# Prerequisite (one-time, the owner's call): macOS must allow Automation Mode. Without it the
# run fails with "Timed out while enabling automation mode". Either approve the
# authentication prompt when it appears, or run once:
#   automationmodetool enable-automationmode-without-authentication
# (Some setups also ask to allow Xcode / "Xcode Helper" under Privacy & Security ›
# Accessibility.)
set -eu

# Automation Mode off → one clear instruction instead of a 5-minute "Timed out while enabling
# automation mode" from xcodebuild. (COMMS_SKIP_AUTOMATION_CHECK=1 skips this check.)
if [ "${COMMS_SKIP_AUTOMATION_CHECK:-0}" != 1 ] && command -v automationmodetool >/dev/null 2>&1; then
  status=$(automationmodetool 2>&1 || true)
  if ! printf '%s\n' "$status" | grep -qi 'Automation Mode is enabled' \
     && printf '%s\n' "$status" | grep -qi 'requires user authentication'; then
    echo "Mac UI tests need macOS Automation Mode. Run this once in Terminal (asks for an admin password), then re-run this script:" >&2
    echo "    automationmodetool enable-automationmode-without-authentication" >&2
    exit 2
  fi
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dd=${DERIVED_DATA:-"${TMPDIR:-/tmp}/comms-mac-ui/dd"}
result=${RESULT_BUNDLE:-"${TMPDIR:-/tmp}/comms-mac-ui/mac-ui.xcresult"}
runner="$dd/Build/Products/Debug/CommsMacUITests-Runner.app"
sign="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="

rm -rf "$runner" "$result"
# shellcheck disable=SC2086
xcodebuild build-for-testing -project "$repo/Apps/Comms.xcodeproj" -scheme CommsMac \
  -destination 'platform=macOS' -derivedDataPath "$dd" $sign -quiet

ent=$(mktemp)
codesign -d --entitlements - --xml "$runner" > "$ent" 2>/dev/null
plutil -remove 'com\.apple\.application-identifier' "$ent" 2>/dev/null || true
codesign --force --sign - --entitlements "$ent" --timestamp=none --generate-entitlement-der "$runner"
rm -f "$ent"

status=0
xcodebuild test-without-building -project "$repo/Apps/Comms.xcodeproj" -scheme CommsMac \
  -destination 'platform=macOS' -derivedDataPath "$dd" -resultBundlePath "$result" "$@" || status=$?

# The Mac UI-test runner is sandboxed and cannot write into the repo, so the screenshots
# (XCTAttachments named mac-<step>[-light|-dark]) are exported from the result bundle.
if [ -d "$result" ]; then
  att=$(mktemp -d)
  xcrun xcresulttool export attachments --path "$result" --output-path "$att" >/dev/null
  mkdir -p "$repo/design/refs/live"
  /usr/bin/python3 - "$att" "$repo/design/refs/live" <<'PY'
import json, re, shutil, sys
att, out = sys.argv[1], sys.argv[2]
n = 0
for test in json.load(open(f"{att}/manifest.json")):
    for a in test["attachments"]:
        m = re.match(r"(mac-[A-Za-z0-9-]+)_\d+_", a["suggestedHumanReadableName"])
        if m and a["exportedFileName"].endswith(".png"):
            shutil.copyfile(f"{att}/{a['exportedFileName']}", f"{out}/{m.group(1)}.png")
            n += 1
print(f"exported {n} screenshots to {out}")
PY
  rm -rf "$att"
fi
exit "$status"
