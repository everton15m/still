#!/bin/bash
# Build the installer in the workspace; installation requires macOS authorization.
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_ROOT="$PWD"
TASK_STAGE="$TASK_ROOT/.build/ntfs-package-root"
TASK_SUPPORT="$TASK_STAGE/Library/Application Support/NTFSBridge"
test -x build/driver/bin/ntfsbridge-check || { echo 'Run scripts/build-ntfs-driver.sh first.' >&2; exit 1; }
swift build -c release --product NTFSBridgeHelper
TASK_PRODUCTS="$(swift build -c release --show-bin-path)"
rm -rf "$TASK_STAGE"
mkdir -p "$TASK_SUPPORT/Driver" "$TASK_SUPPORT/Locks" Still/Resources
cp "$TASK_PRODUCTS/NTFSBridgeHelper" "$TASK_SUPPORT/"
printf '0.1.4\n' > "$TASK_SUPPORT/Version"
for TASK_FOLDER in bin lib Source Licenses; do
    mkdir -p "$TASK_SUPPORT/Driver/$TASK_FOLDER"
    cp -R "build/driver/$TASK_FOLDER/." "$TASK_SUPPORT/Driver/$TASK_FOLDER/"
done
# Complete first-party rebuild sources; omit generated products and the pkg itself.
COPYFILE_DISABLE=1 tar --exclude=.build --exclude=build --exclude=dist --exclude=VendorCache --exclude=.git --exclude=.swiftpm --exclude=xcuserdata --exclude=.DS_Store --exclude=Still/Resources/NTFSBridgeHelper.pkg -czf "$TASK_SUPPORT/Driver/Source/Still-source.tar.gz" .
cp docs/ntfs/DEPENDENCIES.md "$TASK_SUPPORT/Driver/Licenses/"
chmod -R u=rwX,go=rX "$TASK_STAGE"
chmod 700 "$TASK_SUPPORT/Locks"
codesign --force --sign - "$TASK_SUPPORT/NTFSBridgeHelper"
for TASK_FILE in "$TASK_SUPPORT/Driver/bin/"* "$TASK_SUPPORT/Driver/lib/"*; do
    codesign --force --sign - "$TASK_FILE"
done
COPYFILE_DISABLE=1 pkgbuild --root "$TASK_STAGE" --ownership recommended --identifier org.ntfsbridge.helper --version 0.1.4 --scripts Packaging/HelperScripts --install-location / Still/Resources/NTFSBridgeHelper.pkg
shasum -a 256 Still/Resources/NTFSBridgeHelper.pkg
