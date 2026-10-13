# Dependencies and redistribution

The Swift app and helper are MIT-licensed. `Driver/ntfsbridge-check.c` and `Tests/Fixtures/set-dirty.c` are GPL-2.0-or-later and link the upstream GPL NTFS library. They are independent executables; the Swift components invoke them as processes.

The helper installer includes:

- NTFS-3G and ntfs-3g.probe 2026.9.28, GPL-2.0-or-later, with upstream source archive, COPYING, COPYING.LIB and AUTHORS.
- `ntfsbridge-check`, GPL-2.0-or-later, with its source and build script.
- macFUSE's LGPL libfuse2 binary from 5.4.0, with the Library-2 source at commit `fe59bf43f1a2f249ed8d82c7d28739121ee703a2`, the exact gitlink in macFUSE's release tag. Its install name is changed to the protected Driver/lib directory and it is re-signed locally. NTFS-3G links dynamically to it, allowing replacement/relinking. The matching source archive includes its license texts. The macFUSE package's License.rtf is also retained.

The GPL/LGPL archives are installed under `/Library/Application Support/NTFSBridge/Driver/Source`. Rebuild with `Scripts/build-driver.sh`; the app source archive includes this script. To replace/rebuild libfuse, use the provided upstream Library-2 source and its build instructions, preserve ABI 2, set its install name to the same protected path, re-sign, and install through a reviewed administrator-authorized package. LGPL rights to modify the library are not restricted by this app.

macFUSE's FSKit module and MFMount framework are installed separately from the official macFUSE installer. The complete bridge is not fully open source. Its umbrella binary license restricts commercial bundling and automated installation. This app does not redistribute its full installer or bridge. Do not infer unrestricted commercial redistribution rights from free personal use. [macFUSE license](https://github.com/macfuse/macfuse/blob/release/macfuse/LICENSE.txt), [LGPL library guidance](https://github.com/macfuse/macfuse/wiki/Getting-Started-%28Developer%29).

The driver is statically linked with libntfs-3g, with external FUSE selected and plugins and crypto tools disabled. Production executables do not depend on Homebrew libraries. The root helper refuses user-writable executable/library paths. Homebrew is used only to supply unprivileged developer build tools (autoconf, automake, libtool, pkgconf and libgcrypt's configure macro); these are not installed by the app.

Pinned downloads (SHA-256):

| Download | Hash |
|---|---|
| NTFS-3G GitHub tag archive 2026.9.28 | `8a75293f07bf40df5701d296de32a4cb0e46d6ae135abb4f41b438df9868a390` |
| macFUSE 5.4.0 dmg | `861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5` |
| Matching libfuse2 commit archive | `9da29a18ba25c43f310b2e94d997c0ee35d7fcbf92c1465e944610eecb22d4ac` |

The NTFS GitHub archive hash is corroborated by the current [macOS build formula](https://github.com/gromgit/homebrew-fuse/blob/main/Formula/ntfs-3g-mac.rb); macFUSE publishes its dmg hash in [release notes](https://macfuse.github.io/2026/09/07/macfuse-5.4.0.html). The library source commit comes from the signed umbrella release tag; its archive hash was measured locally and pinned. Automated fetching never bypasses TLS certificate verification. The official Tuxera tarball endpoint failed TLS verification on this host; the GitHub tag archive was used instead.
