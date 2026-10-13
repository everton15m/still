# Installation and everyday use

## Requirements

Apple Silicon Mac, macOS 15.4 or newer, administrator account, official macFUSE 5.x, version 5.4.0 or newer, and this project's helper package. Compiled locally on macOS 27.0.1 with Xcode 26.6. Other OS versions and physical Finder write mounting remain unverified; see VERIFICATION.md before entrusting valuable drives.

## Setup using the GUI

1. Open `build/dist/NTFSBridge.app`, then **Set Up…**. Move the app to Applications if you want to keep it.
2. Use **Open macFUSE downloads** to obtain the official installer. Install it using macOS Installer, authorizing its installation yourself. The app does not automatically install macFUSE.
3. If prompted, enable macFUSE's **FSKit file system extension** in System Settings → General → Login Items & Extensions → File System Extensions. Labels can differ between macOS versions. Use the current [official instructions](https://github.com/macfuse/macfuse/wiki/Getting-Started). FSKit does not require Recovery Mode, Reduced Security, or disabling SIP. This app always passes `backend=fskit`; it never falls back to the kernel backend.
4. In NTFSBridge, choose **Open Helper Installer…**. Review and authorize `NTFSBridgeHelper.pkg` in macOS Installer. It installs the helper, NTFS executables, libfuse, licenses and source archives under `/Library/Application Support/NTFSBridge`. It installs no LaunchDaemon, privileged service, fstab rule or system mount replacement.
5. Click **Done**. Reopen or refresh NTFSBridge if needed. Installation detection means files are present; actual mount success is checked separately.

The delivered local build is ad-hoc signed and the installer is unsigned, without Developer ID notarization. Gatekeeper may require explicit approval through Privacy & Security. Do not disable Gatekeeper or run commands stripping quarantine globally. Broad public distribution needs reviewed signing and notarization using the distributor's Apple Developer account; no credentials are assumed here.

## Use

Connect the drive, select **Enable Write Access**, close files on the volume, and confirm. macOS asks for administrator authorization to execute the already-installed helper. It checks root ownership, device attachment identity, external physical NTFS eligibility, exclusive access, hibernation, dirty flags and journal state. It mounts below `/Volumes` and verifies macOS mount flags before the interface shows **Read & write**. Then choose **Open in Finder** and use normal Finder operations.

Eject through the app or Finder before disconnecting. The app's eject button ejects the entire physical drive, including other partitions. Busy ejections are refused; close open files and retry. The menu-bar item is optional under the NTFSBridge menu.

Native exFAT, FAT32, APFS and HFS+ volumes retain their macOS drivers. The NTFS helper never handles them. Read-only media, encrypted volumes and unsupported states do not gain write access. Windows naming restrictions apply to newly created NTFS names. Mounts use `nosuid,nodev,noexec` for removable-data safety; this utility is for documents/data rather than executing programs from the drive.

## A refusal after using Windows

Update the helper using the bundled installer, then choose **Check NTFS…** on the read-only NTFS row. Close open files first. This temporarily unmounts the NTFS volume, checks metadata through a read-only raw-device open, and restores and verifies an Apple NTFS read-only mount. It never repairs, resets a log, deletes hibernation, invokes a write-capable probe, or enables writes. Other partitions stay mounted. Use **Copy Report** to share the check result without directory listings or private filenames.

Hibernation-file detection and cached version-2 journal refusal are different findings; status 14 alone does not identify which happened. Connecting to Windows alone is not proof of a full shutdown, safe eject, or successful filesystem repair. A clean journal flag alone does not override NTFS-3G's cached-state refusal. Preserve a separate verified backup before repair.

## Errors and permissions

- Dirty or hibernated: return to Windows, back up readable files, check the volume if needed, disable Fast Startup and fully shut down Windows, then safely eject. The app does not force-mount, replay the log, remove hibernation files or run repair tools.
- Encrypted/unsupported: unlock with supported software on the appropriate system. BitLocker and EFS are not implemented.
- FSKit mount fails: check the extension's enabled state, installed version and privacy approvals. There is no silent kernel fallback. The helper attempts a native read-only mount and verifies it; a failed fallback is reported explicitly.
- Permission denied: grant removable-volume access if macOS requests it. The app does not silently grant privacy permissions or request blanket Full Disk Access. Current installed macFUSE may have its own requirements; follow its official instructions for that component.
- Unsafe installation ownership: reinstall the helper through Installer. Homebrew executables and libraries are intentionally not used by the administrator helper.
- Unexpected removal: treat recent writes as potentially incomplete; check the drive on Windows before re-enabling writing. Removal monitoring runs only while the app is open; Finder ejection and cable loss can both trigger the advisory.

## Updates and removal

Eject all NTFSBridge-mounted drives before updating the helper. Re-run the physical test matrix after macOS or macFUSE updates. Use the official macFUSE uninstaller when no other FUSE utilities need it. To remove NTFSBridge, first eject its drives and quit the app, remove the app in Finder, then remove its own `/Library/Application Support/NTFSBridge` folder with administrator authorization. No other system files need replacement or restoration.
