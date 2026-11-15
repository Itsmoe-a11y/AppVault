# AppVault

**Native iOS App & Full AppData Backup/Restore Utility for TrollStore and Jailbroken Devices**

AppVault is a modern, unsandboxed SwiftUI application for iOS (iOS 14.0+) designed to perform complete, bit-level backups and restorations of installed applications, their complete data containers (`Documents/`, `Library/Preferences/`, `Library/Application Support/`), and shared `AppGroup` containers.

---

## Highlights

- **Zero-Staging Streaming Compression**: Streams POSIX UStar tar headers and file bytes directly into `zlib` deflate and emits compressed chunks on-the-fly. Eliminates intermediate file duplication and saves up to 50% temporary disk space during backup!
- **Direct Google Drive Streaming (0 MB Device Storage)**: Stream backup archives directly to Google Drive via chunked Resumable Upload sessions (`PUT bytes START-END/TOTAL`). No local archive is created or saved to disk—perfect for devices that are almost full.
- **Cloud Backup Manager**: Connect via OAuth 2.0 PKCE to view, download, restore, or delete backups stored in the `AppVault Backups` folder on Google Drive.
- **Complete Data Preservation**: Unlike standard iOS backups, AppVault backs up the app's internal keychain references, user defaults, SQLite/Realm databases, offline caches, and document stores.
- **Shared App Groups Support**: Automatically discovers and backs up `/var/mobile/Containers/Shared/AppGroup/<UUID>/` associated with applications (crucial for WhatsApp, Telegram, Discord, and widget-enabled apps).
- **Two Backup Modes**:
  - **Full (App + Data)**: Preserves the `.app` bundle, container data, and shared groups. Enables restoring and re-installing apps even if they are removed from the App Store.
  - **Data-Only**: Creates compact archives of user data, game saves, and login sessions for quick migration and snapshotting.
- **Intelligent Restoration Engine**:
  - Gracefully terminates running app instances before data replacement.
  - Automatically restores data and group directories.
  - **POSIX Permissions Repair**: Automatically resets ownership to `mobile:mobile` (`501:501`) and applies `0755`/`0644` permissions so restored apps launch without sandbox or permission crashes.
- **Built-in Share & Import**:
  - Export `.adbk` / `.zip` packages via AirDrop, Save to Files, or cloud storage.
  - Import external `.adbk` archives directly with the native iOS Document Picker.
- **Zero Third-Party Dependencies**: Runs natively using Apple's built-in frameworks (`Foundation`, `SwiftUI`, `UniformTypeIdentifiers`, Darwin POSIX runtime, and `/usr/bin/ditto`).

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                        AppVault (SwiftUI Native)                       │
│  ├── Tab 1: Applications (Installed Apps, Real-time Disk Calculation)  │
│  ├── Tab 2: Backups (Archives List, Restore, Share, Import, Delete)    │
│  └── Tab 3: System & Storage (Disk Space, Diagnostics, Purge Cache)    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────┴────────────────────────────────────┐
│                             Core Services                              │
│                                                                        │
│  1. AppDiscoveryService                                                │
│     - Queries LSApplicationWorkspace via Objective-C reflection        │
│     - Resolves bundle path, data container, and AppGroup containers    │
│     - Asynchronously calculates app and data sizes                     │
│                                                                        │
│  2. BackupEngine                                                       │
│     - Packages Payload/, Data/, AppGroups/, and BackupMetadata.plist   │
│     - Excludes temporary caches on demand                              │
│     - Compresses into .adbk archives using Apple ditto                 │
│                                                                        │
│  3. RestoreEngine                                                      │
│     - Terminates app processes via posix_spawn killall                 │
│     - Restores container files atomically                              │
│     - Executes recursive chown 501:501 to prevent permission errors     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Installation

### Via TrollStore (Recommended)
1. Download the latest `AppVault.tipa` (or `AppVault.ipa`) from the [Releases](https://github.com/Itsmoe-a11y/AppVault/releases) tab.
2. Open with TrollStore and tap **Install**.
3. Launch **AppVault** from your Home Screen.

---

## Building from Source

### Prerequisites
- macOS with Xcode 15+
- `xcodegen` (`brew install xcodegen`)
- `ldid` (`brew install ldid`)

### Compile and Package
```bash
git clone https://github.com/Itsmoe-a11y/AppVault.git
cd AppVault
chmod +x tools/build-app.sh
./tools/build-app.sh .
```
This produces `AppVault.ipa` and `AppVault.tipa` in the project root.

---

## License

This project is licensed under the MIT License.
