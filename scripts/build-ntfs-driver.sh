#!/bin/bash
# Builds in the workspace only. Does not install anything or request privileges.
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_ROOT="$PWD"
CACHE="$TASK_ROOT/VendorCache"
OUT="$TASK_ROOT/build/driver"
mkdir -p "$CACHE" "$OUT/bin" "$OUT/lib" "$OUT/Licenses" "$OUT/Source"
VERSION=2026.9.28
SOURCE_SHA=8a75293f07bf40df5701d296de32a4cb0e46d6ae135abb4f41b438df9868a390
FUSE_SHA=861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5
fetch() { test -f "$2" || curl --fail --location --silent --show-error "$1" -o "$2"; }
check() { test "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$2" || { echo "Checksum mismatch: $1" >&2; exit 1; }; }
fetch "https://github.com/tuxera/ntfs-3g/archive/refs/tags/$VERSION.tar.gz" "$CACHE/ntfs-3g-$VERSION.tar.gz"
check "$CACHE/ntfs-3g-$VERSION.tar.gz" "$SOURCE_SHA"
fetch "https://github.com/macfuse/macfuse/releases/download/macfuse-5.4.0/macfuse-5.4.0.dmg" "$CACHE/macfuse-5.4.0.dmg"
check "$CACHE/macfuse-5.4.0.dmg" "$FUSE_SHA"
if ! test -d "$CACHE/macfuse-extracted"; then
    MOUNT_DIR=$(mktemp -d /tmp/ntfsbridge-fuse.XXXXXX)
    trap 'hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true; rmdir "$MOUNT_DIR" 2>/dev/null || true' EXIT
    hdiutil attach -readonly -nobrowse -noautoopen "$CACHE/macfuse-5.4.0.dmg" -mountpoint "$MOUNT_DIR" >/dev/null
    pkgutil --expand-full "$MOUNT_DIR/Install macFUSE.pkg" "$CACHE/macfuse-extracted"
    hdiutil detach "$MOUNT_DIR" >/dev/null
    rmdir "$MOUNT_DIR"
    trap - EXIT
fi
FUSE_PAYLOAD="$CACHE/macfuse-extracted/Core.pkg/Payload"
# The LGPL libfuse is copied to our protected installation. The macFUSE FSKit
# extension and MFMount framework are installed separately by its official pkg.
cp "$FUSE_PAYLOAD/usr/local/lib/libfuse.2.dylib" "$OUT/lib/"
install_name_tool -id '/Library/Application Support/NTFSBridge/Driver/lib/libfuse.2.dylib' "$OUT/lib/libfuse.2.dylib"
codesign --force --sign - "$OUT/lib/libfuse.2.dylib"
ln -sf libfuse.2.dylib "$OUT/lib/libfuse.dylib"
test -d "$CACHE/ntfs-3g-$VERSION" || tar -xzf "$CACHE/ntfs-3g-$VERSION.tar.gz" -C "$CACHE"
cd "$CACHE/ntfs-3g-$VERSION"
export ACLOCAL_PATH="/opt/homebrew/share/aclocal:/usr/local/share/aclocal"
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/libtool/libexec/gnubin:/usr/local/bin:$PATH"
for TOOL in autoconf automake glibtoolize pkg-config; do command -v "$TOOL" >/dev/null || { echo "Missing build tool: $TOOL. Install autoconf automake libtool pkgconf libgcrypt." >&2; exit 1; }; done
./autogen.sh
# Override pkg-config output to avoid linking any Homebrew library.
export FUSE_MODULE_CFLAGS="-I$FUSE_PAYLOAD/usr/local/include/fuse -D_FILE_OFFSET_BITS=64"
export FUSE_MODULE_LIBS="-L$OUT/lib -lfuse -pthread"
# Spaces in workspace paths are not reliably handled by upstream Makefiles.
# Use a space-free symlink for the compiler's include and library switches.
BUILD_LINK=$(mktemp -d /tmp/ntfsbridge-build.XXXXXX)
trap 'rm -f "$BUILD_LINK/fuse" "$BUILD_LINK/driver"; rmdir "$BUILD_LINK"' EXIT
ln -s "$FUSE_PAYLOAD/usr/local" "$BUILD_LINK/fuse"
ln -s "$OUT" "$BUILD_LINK/driver"
export FUSE_MODULE_CFLAGS="-I$BUILD_LINK/fuse/include/fuse -D_FILE_OFFSET_BITS=64"
export FUSE_MODULE_LIBS="-L$BUILD_LINK/driver/lib -lfuse -pthread"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export MACOSX_DEPLOYMENT_TARGET=15.4
./configure --prefix=/usr/local --with-fuse=external --disable-shared --enable-static --disable-crypto --disable-plugins --enable-extras
make -j"$(sysctl -n hw.ncpu)"
cp src/ntfs-3g src/ntfs-3g.probe "$OUT/bin/"
# Test tools are never installed by the helper package.
mkdir -p "$TASK_ROOT/build/test-tools"
cp ntfsprogs/mkntfs ntfsprogs/ntfsinfo ntfsprogs/ntfscp ntfsprogs/ntfscat "$TASK_ROOT/build/test-tools/"
"$CC" -std=gnu11 -DHAVE_CONFIG_H -I. -Iinclude/ntfs-3g "$TASK_ROOT/Driver/ntfsbridge-check.c" libntfs-3g/.libs/libntfs-3g.a -framework CoreFoundation -o "$OUT/bin/ntfsbridge-check"
"$CC" -std=gnu11 -DHAVE_CONFIG_H -I. -Iinclude/ntfs-3g "$TASK_ROOT/Tests/Fixtures/set-dirty.c" libntfs-3g/.libs/libntfs-3g.a -framework CoreFoundation -o "$TASK_ROOT/build/test-tools/set-dirty"
"$CC" -std=gnu11 -DHAVE_CONFIG_H -I. -Iinclude/ntfs-3g "$TASK_ROOT/Tests/Fixtures/set-flags.c" libntfs-3g/.libs/libntfs-3g.a -framework CoreFoundation -o "$TASK_ROOT/build/test-tools/set-flags"
"$CC" -std=gnu11 -DHAVE_CONFIG_H -I. -Iinclude/ntfs-3g "$TASK_ROOT/Tests/Fixtures/make-journal.c" libntfs-3g/.libs/libntfs-3g.a -framework CoreFoundation -o "$TASK_ROOT/build/test-tools/make-journal"
for KIND in 1 2 3; do
    "$CC" -std=gnu11 -DHAVE_CONFIG_H -DNTFSBRIDGE_TEST_IO_KIND="$KIND" -I. -Iinclude/ntfs-3g "$TASK_ROOT/Driver/ntfsbridge-check.c" "$TASK_ROOT/Tests/Fixtures/io-error.c" libntfs-3g/.libs/libntfs-3g.a -framework CoreFoundation -o "$TASK_ROOT/build/test-tools/io-error-$KIND"
done
cp "$TASK_ROOT/Driver/ntfsbridge-check.c" "$OUT/Source/"
cp "$TASK_ROOT/scripts/build-ntfs-driver.sh" "$OUT/Source/"
cp COPYING COPYING.LIB AUTHORS "$OUT/Licenses/"
cp "$CACHE/ntfs-3g-$VERSION.tar.gz" "$OUT/Source/"
# Gitlink Library-2 in the signed macfuse-5.4.0 tag identifies the matching source.
fetch "https://github.com/macfuse/library/archive/fe59bf43f1a2f249ed8d82c7d28739121ee703a2.tar.gz" "$CACHE/libfuse2-fe59bf4.tar.gz"
check "$CACHE/libfuse2-fe59bf4.tar.gz" 9da29a18ba25c43f310b2e94d997c0ee35d7fcbf92c1465e944610eecb22d4ac
cp "$CACHE/libfuse2-fe59bf4.tar.gz" "$OUT/Source/"
cp "$FUSE_PAYLOAD/Library/Filesystems/macfuse.fs/Contents/Resources/License.rtf" "$OUT/Licenses/macfuse.rtf"
for EXE in "$OUT/bin/ntfs-3g" "$OUT/bin/ntfs-3g.probe" "$OUT/bin/ntfsbridge-check"; do
    codesign --force --sign - "$EXE"
    otool -L "$EXE"
done
