#!/bin/sh
# Builds Pace in Release and installs it to /Applications.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Pace.xcodeproj -scheme Pace -configuration Release -derivedDataPath build -destination 'platform=macOS' build -quiet
pkill -x Pace || true
rm -rf /Applications/Pace.app
ditto build/Build/Products/Release/Pace.app /Applications/Pace.app
open /Applications/Pace.app
