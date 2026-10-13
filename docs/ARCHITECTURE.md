# Architecture

`Still/` contains the native SwiftUI app and one `@MainActor` observable model. `Sources/StorageCore/` is a dependency-free local Swift package used by both the Xcode app and tests.

The combined app also includes the finalized NTFSBridgeCore module and a small DrivesModel adapter. Drive controls share the same dashboard; the former NTFSBridge frontend is unnecessary. The bundled helper installer remains an explicitly authorized component, with first-party helper source in `Sources/NTFSBridgeHelper/` and dependency/license information in `docs/ntfs/`.

| Component | Responsibility |
| --- | --- |
| `StorageScanner` | Streaming, cancellable metadata traversal on a utility-priority task; mount/symlink exclusions, hard-link deduplication, bounded records, postorder totals, progress and coverage issues. |
| `DiskCapacity` | Startup data-volume capacity through Foundation, independent of the scan. |
| `SuggestionEngine` | Transparent rules for large downloads, older installers, archives, videos, old temporary files, a recognized Homebrew download cache, and large folders. At most six suggestions, low risk before review-required items, then size. |
| `DuplicateDetector` | Size buckets, chunked SHA-256, identity/mtime/ctime checks, final group revalidation. No background hashing or automatic copy selection. |
| `SafetyPolicy` / `TrashService` | Cancellable eligible-item snapshot, exact-path review, explicit confirmation, coordinated revalidation and native Trash move. Duplicate actions coordinate an unchanged retained copy with every selected move. Partial failures are surfaced per item. |
| `LowStorageGate` | Persistent one-alert-per-episode state; recovery above the threshold by max(2 GB, 10% of threshold) rearms it. Failed notification delivery permits retry. |
| `TreemapLayout` | Small balanced binary partition into proportional rectangles; the UI bounds tile count and groups the remainder explicitly. |
| `AppModel` | Connects background results to SwiftUI, controls task cancellation and serialized cleanup, updates inspected results after Trash, and manages capacity checks, notifications and optional login. |
| `DrivesModel` / `NTFSBridgeCore` | External physical-volume inventory and identity checks; Finder, normal whole-disk eject, explicit administrator-authorized NTFS operations, and precise read-only diagnostic reports. |

Only preferences are saved in UserDefaults: threshold, alert opt-in, warned episode, and optional menu-bar visibility. No scan database, file hashes, or filenames are persisted. Network services, AI APIs, and telemetry are absent. Privileged code is confined to the explicitly invoked NTFS helper; it is never used for cleanup or monitoring.

The UI stays on a single scrolling dashboard with overview, connected drives, explorer, and suggestions. A segmented control chooses folder visualization, searchable large files, or on-demand duplicates inside the explorer. All file removal goes through the same confirmation sheet. Existing helper operations retain the independent device lock, root-owned-component validation, FSKit-only backend, and verified read-only restoration; no unsafe mount or repair option is added.
