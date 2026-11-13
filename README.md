# Internet Archive Uploader

A native macOS app for publishing files and folders to the [Internet Archive](https://archive.org)
and keeping them organised there. It talks directly to archive.org's official APIs — no third-party
servers.

## Features

- **New items** — drop a folder or files, arrange folders before uploading (create, rename, move,
  remove), fill in the archive entry (title, identifier with live availability check, description
  with HTML preview, subjects, mediatype, collection, license, custom fields), and upload.
- **My Items** — every item of your account in the sidebar. Three resizable columns per item:
  **Archive Entry** (edit and save metadata) · **Files** (the item's folder tree) · **Upload**.
- **One upload queue** for everything, with a status bar on every screen: pause, resume, stop,
  restart from the beginning, retry failed, reorder, change destinations, remove. The queue is saved
  and comes back (paused) after a restart. Uploads keep running in the background (no App Nap).
- **Folder sync, Finder as the reference** — link a Finder folder to an item. The app compares them
  by path, size and MD5 and lists ordered tasks you can tick on or off: folders → server-side moves
  (detected by checksum, so nothing is re-uploaded) → uploads of new and changed files → removal of
  files not in Finder (last, and only if everything before succeeded).
- **Never uploads twice** — files are matched by full path and content. Identical files are skipped,
  even when they already sit in a different folder of the item.
- **Server-side file management** — rename, move, delete and download files and folders; delete whole
  items in the background.
- **archive.org task queue** — see what archive.org is still processing for an item, including tasks
  paused for staff review.
- Quit guard while uploading, remembered layout and expanded folders, adjustable text size
  (View ▸ Bigger / Smaller).

## Download

Get the latest `Internet-Archive-Uploader-x.y.z-macOS.zip` from
[Releases](https://github.com/alchemy-color/internet-archive-uploader/releases), unzip it and move
**ArchiveUploader.app** to Applications. It runs on Apple Silicon and Intel Macs with macOS 15 or later.

The app is not notarized by Apple, so the first launch is blocked. Open it once, then go to
**System Settings ▸ Privacy & Security** and click **Open Anyway**. Alternatively, in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/ArchiveUploader.app
```

## Requirements

- macOS 15 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and run

```sh
xcodegen generate   # creates IAUploader.xcodeproj from project.yml
./build.sh          # builds and copies ArchiveUploader.app into this folder
open ArchiveUploader.app
```

`build.sh` builds in `$TMPDIR` (override with `DERIVED=...`) so build products stay out of synced
folders. To use your own bundle identifier, change `bundleIdPrefix` and the
`PRODUCT_BUNDLE_IDENTIFIER` values in `project.yml`.

## Test

```sh
./test.sh
```

Unit tests run against a separate data folder (`/tmp/IAUploaderTests-config`) and never touch your
real queue, settings or credentials. Two opt-in tests talk to archive.org:

- `LiveArchiveTests` creates a throwaway item in `test_collection` (removed by archive.org after
  ~30 days). Run with `TEST_RUNNER_IA_LIVE_TEST=1` after copying credentials into the test folder.
- `SyncPreviewTests` prints a read-only sync plan: `TEST_RUNNER_IA_SYNC_PREVIEW_FOLDER=/path`
  `TEST_RUNNER_IA_SYNC_PREVIEW_ITEM=identifier`.

## Privacy and security

- **Your password is never stored.** It is sent once over HTTPS to archive.org's sign-in service,
  which returns your account's S3 keys; the password is then discarded. You can also sign in with S3
  keys directly (archive.org/account/s3.php).
- **S3 keys** are stored in `~/.config/IAUploader/credentials.json` with owner-only permissions
  (0600, folder 0700) — the same approach as archive.org's own command-line tool. They are never
  written inside the project folder. Signing out deletes the file.
- **Keys only go to archive.org.** All requests use HTTPS, and redirects that leave `archive.org`
  are refused or stripped of the `Authorization` header.
- **Local data** (`state.json`, `queue.json`, `md5cache.json` in the same folder) holds file paths,
  item identifiers and checksums so the app can resume and avoid re-uploads. It never leaves your
  Mac. Preferences live in the app's user defaults.
- No analytics, telemetry or third-party services.

Set `IAUPLOADER_CONFIG_DIR=/some/folder` to run a copy of the app against a separate data folder and
preferences domain (used by the tests).

## archive.org notes

- archive.org has no real folders or renames: folders exist through file paths, and a move is a
  server-side copy plus a delete.
- Every change becomes a task in the item's queue, processed in order. The item page can lag minutes
  to hours behind; large batches of deletions may be paused for review by archive.org staff, which
  only they can release.
- Mediatype and collection can't be changed after an item is created. Uploaders can't remove an item
  itself — deleting removes all its files; contact archive.org to remove the identifier.

## Project layout

```
IAUploader/
  App/        App entry, menus, AppModel (state, upload, sync, item management)
  Models/     Credentials, metadata, files, folder tree, upload/queue types
  Services/   archive.org client, upload queue and transport, sync planner,
              file manager, settings, persistence
  Views/      Sidebar, workspace columns, queue, sync, editors, settings
IAUploaderTests/  Unit tests (+ opt-in live tests)
Scripts/          App icon generator
```

## License

See [LICENSE](LICENSE).

---

Not affiliated with or endorsed by the Internet Archive.
