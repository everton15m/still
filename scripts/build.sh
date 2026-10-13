#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Still.xcodeproj -scheme Still -configuration Release -derivedDataPath .build/xcode build CODE_SIGN_IDENTITY=-
printf '\nBuilt: %s/.build/xcode/Build/Products/Release/Still.app\n' "$PWD"
