#!/bin/sh
# Builds Pace and installs it to /Applications.
# Signs with your "Apple Development" certificate. Set DEVELOPMENT_TEAM to pick a team.
set -e
cd "$(dirname "$0")/.."

if [ -z "$DEVELOPMENT_TEAM" ]; then
  DEVELOPMENT_TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')
fi
if [ -z "$DEVELOPMENT_TEAM" ]; then
  echo "No Apple Development certificate found. Sign in to Xcode with an Apple ID (Settings > Accounts),"
  echo "create one under Manage Certificates, then run this again."
  exit 1
fi

command -v xcodegen >/dev/null || { echo "Needs XcodeGen: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project Pace.xcodeproj -scheme Pace -configuration Release -derivedDataPath build \
  -destination 'platform=macOS' DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build -quiet
pkill -x Pace || true
rm -rf /Applications/Pace.app
ditto build/Build/Products/Release/Pace.app /Applications/Pace.app
open /Applications/Pace.app
echo "Installed Pace (team $DEVELOPMENT_TEAM)."
