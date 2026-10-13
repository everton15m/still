# Still

A small, native macOS app for storage cleanup and connected drives. First-party Swift code is MIT licensed, with no accounts, telemetry, subscriptions, or cloud service. Storage cleanup stays offline and unprivileged. Optional NTFS writing uses NTFS-3G, macFUSE's FSKit extension, and an explicitly authorized, short-lived helper.

**Requires an Apple Silicon Mac running macOS 15.4 or later.** Open `Still.xcodeproj` in a compatible Xcode version and run the **Still** scheme. One dashboard contains storage tools and a compact Connected drives card. The local Swift package includes StorageCore and NTFSBridgeCore; no second frontend app is needed.

## Build and install

```sh
./scripts/build.sh
open .build/xcode/Build/Products/Release/Still.app
```

Drag the built `Still.app` to your Applications folder to keep it. The script uses free local ad-hoc signing; no developer account is required. For distributing downloaded builds to other Macs, configure your own Developer ID and notarization. No notarized public release is supplied.

The installed app is `/Applications/Still.app`. Development products are generated under the hidden `.build/xcode` folder to keep them out of normal application discovery. Superseded app copies and archives are removed after installation.

If `xcodebuild` reports that only Command Line Tools are selected, select a full compatible Xcode installation using Xcode's **Settings → Locations → Command Line Tools**. See Apple's [current compatibility matrix](https://developer.apple.com/xcode/system-requirements).

## Use

1. Open Still to see startup-volume capacity immediately.
2. **Scan Storage** inspects accessible startup files. The adjacent menu also scans your home folder or a chosen folder on the startup data volume. Scans can be stopped; partial results stay visible.
3. Click a folder tile to enter it; use the back or home button to navigate. **Rescan** and ⌘R refresh the current folder. Switch to **Large Files** to search, filter by type, select multiple files, and sort by size. Protected files show **Inspection only**; deselect them before reviewing a batch.
4. **Worth a look** shows at most six deterministic suggestions. Review each item; age and size never imply that a file is unnecessary.
5. **Duplicates → Find duplicates** checks eligible, local files of at least 1 MB with SHA-256. Select copies yourself and retain at least one per group. The kept copies are revalidated and coordinated with every move; changed or missing keepers block further moves.
6. Every Trash action shows exact paths and rechecks them after confirmation. Folder review is cancellable with **Cancel Review** or ⌘. before anything moves. Empty Trash yourself in Finder when you are ready. Moving files into Trash alone does not reclaim disk space.
7. Click **Enable alerts** to grant native notification permission. The default threshold is 20 decimal GB; change it in Settings. Closing the window keeps checks running; quitting the app stops them. Optional **Open at login** uses `SMAppService.mainApp` after installation. Optional menu bar indicator opens the dashboard.
8. **Connected drives** opens external volumes in Finder, safely ejects a whole physical drive after confirmation, and offers **Check NTFS** or **Enable Write Access**. NTFS actions require the bundled helper 0.1.3 update and official macFUSE 5.4 or later. Use **Update NTFS Helper / Set Up NTFS** to open Installer and authorize it yourself.

## Permissions and safety

Still is deliberately **not sandboxed**, allowing a startup-volume scan with ordinary user permissions. Full Disk Access is a user-granted privacy setting, not an entitlement. For wider coverage, add your installed app in **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. Folder selection and Files & Folders grants can provide narrower access. The Apple-events entitlement permits the explicit NTFS administrator-authorization flow; storage cleanup never uses that helper. SIP and filesystem permissions still apply and are never weakened.

NTFS safety checks refuse hibernation, cached/unsupported journals, dirty or maintenance flags, unsafe component ownership, and device-identity changes. **Check NTFS** temporarily unmounts the selected NTFS volume, reads metadata without repair or enabling writes, and restores verified native read-only access. A hibernation file and a cached journal now produce distinct explanations. No force mount, journal reset, reformat, or hibernation-file deletion is offered. An unsafe NTFS filesystem may still need Windows repair after a backup; a new app cannot guarantee that a previously unsafe volume is writable. See [NTFS integration and dependency licenses](docs/ntfs/DEPENDENCIES.md).

Cleanup is restricted to user-owned items inside your home folder. Standard home-folder roots, hidden configuration, app bundles, media libraries, databases, system files, cloud items, and unknown Library data are inspection-only. The only recognized Library cache is `~/Library/Caches/Homebrew/downloads`; finish any running Homebrew command before reviewing it. Inaccessible or protected descendants block an entire folder action. Symlinks and mounted volumes are never followed for cleanup.

## Tests

```sh
./scripts/test.sh
# Or run Product → Test in Xcode with the Still scheme:
xcodebuild -project Still.xcodeproj -scheme Still -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode test CODE_SIGN_IDENTITY=-
```

57 tests cover storage inspection, cancellation, permissions, duplicate content and keeper preservation, suggestions, warning hysteresis, treemap proportions, Trash safety, physical-volume eligibility, process-signal handling, NTFS diagnostic stages, and native read-only fallback. Native Trash tests use only their own disposable fixtures. The NTFS component's ten disposable-image scenarios are documented in its integration report.

## Limits

- The explorer is an **inspection estimate**, not a complete breakdown of the disk. Sealed system directories, selected volatile system paths, other volumes, and inaccessible locations are excluded and reported under **Coverage**. Snapshots and APFS container metadata are not scanned.
- The dashboard shows macOS-reported available bytes separately from the important-usage value, which can include reclaimable storage. Warnings use the conservative available bytes.
- Hard links count once in scan totals and are not duplicate copies. APFS clones cannot reliably be distinguished through these metadata APIs. Recoverable-space figures are upper bounds; actual savings can be zero, including while snapshots retain blocks.
- Folder totals include small files; file lists and duplicate comparisons retain files ≥ 1 MB. Metadata is bounded to 100,000 directories, 100,000 file records, and 100,000 hard-link identities. Limits and cancelled scans are labeled; scan smaller folders for more detail. The table shows 500 matches, folder lists 200 entries, and duplicates the 50 largest groups.
- Results are a point-in-time view. There is no continuous filesystem indexing. A successful Trash action removes moved items from the current results and refreshes capacity; other filesystem changes need a fresh scan. All Trash candidates are revalidated regardless.
- Monitoring is an in-process five-minute timer with a one-minute tolerance and wake refresh. It does not run after Quit. Notifications and login items require the corresponding macOS permission/approval.
- External-volume contents are not scanned or cleaned. Their card manages Finder access, explicit NTFS mounting/diagnostics, and normal eject only. Disk Arbitration events and a tolerant one-minute metadata refresh keep the inventory current.
- macFUSE includes closed-source bridge components; the full optional NTFS stack is not entirely open source. Its installation, FSKit approval, and administrator authorization are separate from storage cleanup. No persistent privileged daemon is installed.
- The app does not empty Trash, delete snapshots, uninstall apps, clean unknown caches, or repair NTFS filesystems.

See [research and decisions](docs/RESEARCH.md), [architecture](docs/ARCHITECTURE.md), and [verification](docs/VERIFICATION.md).
