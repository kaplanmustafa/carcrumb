#!/usr/bin/env bash
# Expo SDK 58 (expo-modules-jsi, swift-tools 6.2) needs Xcode 26 or newer.
set -euo pipefail
XCODE=$(ls -d /Applications/Xcode_2[6-9]*.app 2>/dev/null | grep -vi beta | sort -V | tail -1 || true)
if [ -z "$XCODE" ]; then
  echo "No Xcode 26+ found in /Applications:"; ls /Applications; exit 1
fi
sudo xcode-select -s "$XCODE/Contents/Developer"
xcodebuild -version
