# Read-only device-access diagnostics — helper 0.1.4

NTFS-3G's `ntfs_volume_error()` maps `EPERM` to its hibernation status 14. On macOS, opening a raw device can also fail with `EPERM`. The old checker discarded errno and the I/O operation, and the frontend inferred hibernation from the status alone. A report at `volume_open` with unavailable NTFS metadata does not establish hibernation, cached state or corruption.

Helper 0.1.4 preserves numeric `osError`, a fixed `ioOperation`, and whether the library completed its read-only open/lock. Operations distinguish device stat, open, locking, reads, boot reads and later metadata loading. The frontend explains device-access failures separately and treats older incomplete reports as inconclusive.

The checker still opens with RDONLY and FORENSIC flags. Its I/O wrappers additionally reject any non-read-only open and all write/pwrite calls. `writeBlocked` records an attempted write that was refused. No recovery, journal reset, write probe or repair is invoked. Upstream log arguments are never formatted or emitted, since they can contain private filenames. Only hardcoded operation names and numeric errors enter the report.

`diagnose` revalidates UUID and I/O Registry attachment identity, unmounts only the NTFS partition without force, checks metadata, and restores and verifies native Apple read-only access. Busy mounts are refused. The helper reports no successful diagnostic if read-only restoration fails.

## Reading a report

- `volume_open`, errno 1 or 13, `device_open`: OS access was denied before NTFS safety checks. Investigate permissions/privacy using local macOS logs. This is not a hibernation verdict.
- `volume_open`, `device_lock`: the library could not obtain its read lock. Do not bypass the lock.
- `volume_open`, `device_read` or `boot_read`: reading failed. Preserve the OS error; distinguish access errors from I/O or removal failures.
- `volume_open`, `volume_metadata`: opening progressed, but loading the filesystem failed. No hibernation or journal verdict is available.
- `hiber_file`: the explicit hibernation-file check ran and refused the state.
- `cached_journal`: the explicit journal check identified version 2.0; the existing conservative NTFS-3G refusal remains intact.

Administrator authorization alone does not override macOS privacy controls. Privacy changes are a separate user decision. Local ad-hoc rebuilds can invalidate an earlier Full Disk Access approval; reapproval may be needed after installing a different build. An EPERM report alone does not prove that Full Disk Access is the specific cause.

## Validation and current physical-drive limit

60 Swift tests pass (34 storage and 26 NTFS). Thirteen disposable-image scenarios pass, including injected EPERM at open and lock, and EIO while reading. Error numbers and operations survive, hibernation/journal remain unchecked for early failures, private log arguments do not appear, and SHA-256 hashes remain unchanged. Clean, dirty, hibernated and both clean/unclean journal versions retain the prior refusal policy. Release Still 1.2.1 and helper 0.1.4 compile successfully; the installer payload matches the tested checker and uses root-owned executable paths.

The previously observed physical-drive report stopped at `volume_open`, code 14, with all NTFS fields unavailable. The drive was disconnected during this update. Its exact failing OS operation requires a fresh report through the updated, administrator-installed helper on the reconnected drive. No repair or physical-drive write test has been performed.
