#!/bin/bash
# Makes build/FamiliarTest.app: the built app under its own bundle id (io.github.kaushicaravind2000.Familiar.test), so a test
# copy never hands over to, or shares settings with, the Familiar you use. Launch it with
#   open -n --env FAMILIAR_INDEX=<test index> --env FAMILIAR_LOGS=<test logs> --env FAMILIAR_NO_HOTKEY=1 \
#        build/FamiliarTest.app --args …
# and give it settings with `defaults write io.github.kaushicaravind2000.Familiar.test …`.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/FamiliarTest.app
ditto build/Familiar.app build/FamiliarTest.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.kaushicaravind2000.Familiar.test" build/FamiliarTest.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleName FamiliarTest" build/FamiliarTest.app/Contents/Info.plist
codesign --force --sign - --options runtime --entitlements Resources/Familiar.entitlements build/FamiliarTest.app 2>/dev/null
echo "Built build/FamiliarTest.app"
